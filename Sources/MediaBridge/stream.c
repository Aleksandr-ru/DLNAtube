#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/mathematics.h>
#include <libavutil/time.h>
#include <sys/socket.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>

typedef struct {
    int fd;
} SocketOutput;

typedef int (*RangeFetch)(void *opaque, int stream_index, int64_t offset,
                          uint8_t *buffer, int size);
typedef void (*StartNotice)(void *opaque, double actual_start);

typedef struct {
    int index;
    int64_t position;
    int64_t size;
    void *opaque;
    RangeFetch fetch;
} InputSource;

// Keep only a small amount of media buffered by the TV. Some older DLNA
// renderers stop as soon as the HTTP response reaches EOF instead of playing
// everything they have accepted into a large network buffer.
static const int64_t OUTPUT_LEAD_US = 3 * AV_TIME_BASE;

static void pace_packet(const AVPacket *packet, const AVStream *stream,
                        int64_t origin_us, int64_t wall_start_us) {
    int64_t timestamp = packet->dts == AV_NOPTS_VALUE ? packet->pts : packet->dts;
    if (timestamp == AV_NOPTS_VALUE) return;
    int64_t media_us = av_rescale_q(timestamp, stream->time_base, AV_TIME_BASE_Q) - origin_us;
    if (media_us <= OUTPUT_LEAD_US) return;
    int64_t target_us = wall_start_us + media_us - OUTPUT_LEAD_US;
    int64_t now_us = av_gettime_relative();
    while (target_us > now_us) {
        int64_t delay_us = target_us - now_us;
        av_usleep((unsigned int)(delay_us > 500000 ? 500000 : delay_us));
        now_us = av_gettime_relative();
    }
}

static int send_all(int fd, const uint8_t *bytes, int count) {
    int sent = 0;
    while (sent < count) {
        ssize_t n = send(fd, bytes + sent, (size_t)(count - sent), 0);
        if (n <= 0) return AVERROR(errno ? errno : EPIPE);
        sent += (int)n;
    }
    return sent;
}

static int write_packet(void *opaque, const uint8_t *buffer, int size) {
    return send_all(((SocketOutput *)opaque)->fd, buffer, size);
}

static int read_input(void *opaque, uint8_t *buffer, int size) {
    InputSource *source = opaque;
    if (source->position >= source->size) return AVERROR_EOF;
    int64_t remaining = source->size - source->position;
    if (size > remaining) size = (int)remaining;
    int count = source->fetch(source->opaque, source->index,
                              source->position, buffer, size);
    if (count <= 0) return count < 0 ? AVERROR(EIO) : AVERROR_EOF;
    source->position += count;
    return count;
}

static int64_t seek_input(void *opaque, int64_t offset, int whence) {
    InputSource *source = opaque;
    if (whence == AVSEEK_SIZE) return source->size;
    int mode = whence & ~AVSEEK_FORCE;
    int64_t target;
    if (mode == SEEK_SET) target = offset;
    else if (mode == SEEK_CUR) target = source->position + offset;
    else if (mode == SEEK_END) target = source->size + offset;
    else return AVERROR(EINVAL);
    if (target < 0 || target > source->size) return AVERROR(EINVAL);
    source->position = target;
    return target;
}

static int open_input(AVFormatContext **context, AVIOContext **io,
                      InputSource *source) {
    *context = avformat_alloc_context();
    if (!*context) return AVERROR(ENOMEM);
    uint8_t *buffer = av_malloc(65536);
    if (!buffer) return AVERROR(ENOMEM);
    *io = avio_alloc_context(buffer, 65536, 0, source, read_input, NULL, seek_input);
    if (!*io) { av_free(buffer); return AVERROR(ENOMEM); }
    (*context)->pb = *io;
    (*context)->flags |= AVFMT_FLAG_CUSTOM_IO;
    const AVInputFormat *format = av_find_input_format("mov");
    if (!format) return AVERROR_DEMUXER_NOT_FOUND;
    return avformat_open_input(context, NULL, format, NULL);
}

// Each GET starts a fresh remux. No media is retained on disk.
int dlnatube_stream_ts(int64_t video_size, int64_t audio_size,
                       double start_seconds, int client_fd,
                       void *opaque, RangeFetch fetch, StartNotice notice) {
    AVFormatContext *input[2] = {NULL, NULL};
    AVIOContext *input_io[2] = {NULL, NULL};
    AVFormatContext *output = NULL;
    AVIOContext *io = NULL;
    AVPacket *packet[2] = {NULL, NULL};
    int source_stream[2] = {-1, -1};
    int result = 0, response_sent = 0;
    SocketOutput socket_output = {.fd = client_fd};
    InputSource source[2] = {
        {.index = 0, .size = video_size, .opaque = opaque, .fetch = fetch},
        {.index = 1, .size = audio_size, .opaque = opaque, .fetch = fetch}
    };

    if (video_size <= 0 || audio_size <= 0 || !fetch) {
        result = AVERROR(EINVAL);
        goto cleanup;
    }
    result = open_input(&input[0], &input_io[0], &source[0]);
    if (result < 0) goto cleanup;
    result = open_input(&input[1], &input_io[1], &source[1]);
    if (result < 0) goto cleanup;
    source_stream[0] = av_find_best_stream(input[0], AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    source_stream[1] = av_find_best_stream(input[1], AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (source_stream[0] < 0 || source_stream[1] < 0) {
        result = AVERROR_STREAM_NOT_FOUND;
        goto cleanup;
    }
    if (start_seconds > 0) {
        for (int i = 0; i < 2; i++) {
            AVRational base = input[i]->streams[source_stream[i]]->time_base;
            int64_t target = av_rescale_q((int64_t)(start_seconds * AV_TIME_BASE),
                                          AV_TIME_BASE_Q, base);
            result = av_seek_frame(input[i], source_stream[i], target, AVSEEK_FLAG_BACKWARD);
            if (result < 0) goto cleanup;
        }
    }
    result = avformat_alloc_output_context2(&output, NULL, "mpegts", NULL);
    if (result < 0) goto cleanup;
    for (int i = 0; i < 2; i++) {
        AVStream *target = avformat_new_stream(output, NULL);
        if (!target) { result = AVERROR(ENOMEM); goto cleanup; }
        result = avcodec_parameters_copy(target->codecpar,
                                         input[i]->streams[source_stream[i]]->codecpar);
        if (result < 0) goto cleanup;
        target->codecpar->codec_tag = 0;
        target->time_base = input[i]->streams[source_stream[i]]->time_base;
    }
    uint8_t *buffer = av_malloc(32768);
    if (!buffer) { result = AVERROR(ENOMEM); goto cleanup; }
    io = avio_alloc_context(buffer, 32768, 1, &socket_output, NULL, write_packet, NULL);
    if (!io) { av_free(buffer); result = AVERROR(ENOMEM); goto cleanup; }
    output->pb = io;
    output->flags |= AVFMT_FLAG_CUSTOM_IO;

    for (int i = 0; i < 2; i++) {
        packet[i] = av_packet_alloc();
        if (!packet[i]) { result = AVERROR(ENOMEM); goto cleanup; }
    }
    do {
        result = av_read_frame(input[0], packet[0]);
        if (result < 0) goto cleanup;
        if (packet[0]->stream_index == source_stream[0]) break;
        av_packet_unref(packet[0]);
    } while (1);
    AVStream *video_stream = input[0]->streams[source_stream[0]];
    if (start_seconds > 0) {
        int64_t desired = av_rescale_q((int64_t)(start_seconds * AV_TIME_BASE),
                                       AV_TIME_BASE_Q, video_stream->time_base);
        int64_t fallback = packet[0]->pts;
        if (fallback != AV_NOPTS_VALUE && fallback < desired) {
            while (1) {
                av_packet_unref(packet[0]);
                result = av_read_frame(input[0], packet[0]);
                if (result < 0) break;
                if (packet[0]->stream_index == source_stream[0] &&
                    (packet[0]->flags & AV_PKT_FLAG_KEY) &&
                    packet[0]->pts != AV_NOPTS_VALUE && packet[0]->pts >= desired) break;
            }
            int use_previous = result < 0 ||
                (packet[0]->pts != AV_NOPTS_VALUE &&
                 desired - fallback < packet[0]->pts - desired);
            if (use_previous) {
                result = av_seek_frame(input[0], source_stream[0], fallback,
                                       AVSEEK_FLAG_BACKWARD);
                if (result < 0) goto cleanup;
                do {
                    result = av_read_frame(input[0], packet[0]);
                    if (result < 0) goto cleanup;
                    if (packet[0]->stream_index == source_stream[0]) break;
                    av_packet_unref(packet[0]);
                } while (1);
            }
        }
    }
    int64_t video_start = packet[0]->pts == AV_NOPTS_VALUE ? packet[0]->dts : packet[0]->pts;
    int64_t origin_us = video_start == AV_NOPTS_VALUE ? 0 :
        av_rescale_q(video_start, video_stream->time_base, AV_TIME_BASE_Q);
    if (notice) notice(opaque, origin_us / 1000000.0);
    char headers[320];
    int header_size = snprintf(headers, sizeof(headers),
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: video/mpeg\r\n"
        "transferMode.dlna.org: Streaming\r\n"
        "contentFeatures.dlna.org: DLNA.ORG_PN=AVC_TS_MP_HD_AAC_ISO;DLNA.ORG_OP=00\r\n"
        "X-DlnaTube-Start: %.3f\r\n"
        "Connection: close\r\n\r\n", origin_us / 1000000.0);
    if (header_size <= 0 || header_size >= (int)sizeof(headers)) {
        result = AVERROR(EINVAL);
        goto cleanup;
    }

    result = send_all(client_fd, (const uint8_t *)headers, header_size);
    if (result < 0) goto cleanup;
    response_sent = 1;
    result = avformat_write_header(output, NULL);
    if (result < 0) goto cleanup;
    int64_t wall_start_us = av_gettime_relative();

    int ready[2] = {1, 0};
    int ended[2] = {0, 0};
    while (!ended[0] || !ended[1]) {
        for (int i = 0; i < 2; i++) {
            if (ready[i] || ended[i]) continue;
            do {
                result = av_read_frame(input[i], packet[i]);
                if (result < 0) { ended[i] = 1; break; }
                if (packet[i]->stream_index != source_stream[i]) {
                    av_packet_unref(packet[i]);
                    continue;
                }
                if (i == 1 && start_seconds > 0 &&
                    packet[i]->pts != AV_NOPTS_VALUE &&
                    av_rescale_q(packet[i]->pts,
                                 input[i]->streams[source_stream[i]]->time_base,
                                 AV_TIME_BASE_Q) < origin_us) {
                    av_packet_unref(packet[i]);
                    continue;
                }
                ready[i] = 1;
            } while (!ready[i]);
        }
        int next = -1;
        if (ready[0] && ready[1]) {
            int64_t a = packet[0]->dts == AV_NOPTS_VALUE ? packet[0]->pts : packet[0]->dts;
            int64_t b = packet[1]->dts == AV_NOPTS_VALUE ? packet[1]->pts : packet[1]->dts;
            next = av_compare_ts(a, input[0]->streams[source_stream[0]]->time_base,
                                 b, input[1]->streams[source_stream[1]]->time_base) <= 0 ? 0 : 1;
        } else if (ready[0]) next = 0;
        else if (ready[1]) next = 1;
        if (next < 0) break;
        AVStream *from = input[next]->streams[source_stream[next]];
        AVStream *to = output->streams[next];
        pace_packet(packet[next], from, origin_us, wall_start_us);
        if (start_seconds > 0) {
            int64_t origin = av_rescale_q(origin_us, AV_TIME_BASE_Q, from->time_base);
            if (packet[next]->pts != AV_NOPTS_VALUE) packet[next]->pts -= origin;
            if (packet[next]->dts != AV_NOPTS_VALUE) packet[next]->dts -= origin;
        }
        av_packet_rescale_ts(packet[next], from->time_base, to->time_base);
        packet[next]->stream_index = next;
        packet[next]->pos = -1;
        result = av_interleaved_write_frame(output, packet[next]);
        ready[next] = 0;
        if (result < 0) goto cleanup;
    }
    result = av_write_trailer(output);

cleanup:
    if (result < 0 && !response_sent) {
        const char *error_response = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
        send_all(client_fd, (const uint8_t *)error_response, (int)strlen(error_response));
    }
    if (result < 0 && result != AVERROR(EPIPE) && result != AVERROR(ECONNRESET)) {
        char error[256];
        av_strerror(result, error, sizeof(error));
        fprintf(stderr, "DlnaTube streaming: %s\n", error);
    }
    for (int i = 0; i < 2; i++) {
        av_packet_free(&packet[i]);
        avformat_close_input(&input[i]);
        if (input_io[i]) {
            av_freep(&input_io[i]->buffer);
            avio_context_free(&input_io[i]);
        }
    }
    if (io) { av_freep(&io->buffer); avio_context_free(&io); }
    avformat_free_context(output);
    return result;
}
