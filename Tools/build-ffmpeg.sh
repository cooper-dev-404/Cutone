#!/bin/bash
# Build the local-file compatibility tools with Apple Command Line Tools on arm64.
# Example: bash Tools/build-ffmpeg.sh ./ffmpeg-8.1.3.tar.xz ./build/media-tools
set -euo pipefail
if [[ $# -ne 2 ]]; then
    echo "Usage: $0 /path/to/ffmpeg-8.1.3.tar.xz /path/to/build-directory" >&2
    exit 2
fi
if [[ "$(uname -m)" != arm64 ]]; then
    echo "Run this build on Apple Silicon." >&2
    exit 2
fi
archive_dir=$(cd "$(dirname "$1")" && pwd)
archive="$archive_dir/$(basename "$1")"
checksum=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
observed=$(shasum -a 256 "$archive" | cut -d' ' -f1)
if [[ "$observed" != "$checksum" ]]; then
    echo "FFmpeg 8.1.3 source checksum does not match." >&2
    exit 1
fi
mkdir -p "$2"
build_root=$(cd "$2" && pwd)
src="$build_root/ffmpeg-8.1.3"
mkdir -p "$build_root/obj" "$build_root/bin" "$build_root/licenses"
tar -xf "$archive" -C "$build_root"
cd "$build_root/obj"
export MACOSX_DEPLOYMENT_TARGET=14.0
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
"$src/configure" \
    --prefix=/usr/local --arch=arm64 --target-os=darwin --cc=clang \
    --disable-autodetect --disable-network --disable-doc --disable-debug \
    --disable-shared --enable-static --enable-small --disable-everything \
    --disable-avdevice --disable-ffplay --enable-ffmpeg --enable-ffprobe \
    --enable-zlib --enable-audiotoolbox --enable-videotoolbox \
    --enable-protocol=file,pipe \
    --enable-demuxer=mov,matroska,avi,mpegts,mpegps,mpegvideo,flv,asf,mxf,ogg,wav,aac,mp3,h264,hevc \
    --enable-muxer=mov,mp4,matroska,ipod,wav \
    --enable-decoder=h264,hevc,mpeg4,mpeg2video,mpeg1video,h263,flv,vc1,wmv1,wmv2,wmv3,vp6,vp6f,vp8,vp9,av1,prores,mjpeg,dvvideo,aac,aac_latm,ac3,eac3,dca,mp3float,mp2float,alac,flac,opus,vorbis,wmav1,wmav2,wmapro,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_f32le \
    --enable-encoder=aac,h264_videotoolbox,hevc_videotoolbox,pcm_s16le \
    --enable-parser=h264,hevc,mpeg4video,mpegvideo,vc1,vp8,vp9,av1,aac,aac_latm,ac3,dca,mpegaudio,opus,flac \
    --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox \
    --enable-bsf=aac_adtstoasc,extract_extradata,h264_mp4toannexb,hevc_mp4toannexb,vp9_superframe,av1_frame_merge \
    --enable-filter=scale,format,aformat,aresample,anull,null,fps,transpose,hflip,vflip
make -j"$(getconf _NPROCESSORS_ONLN)" ffmpeg ffprobe
for tool in ffmpeg ffprobe; do
    install -m 755 "$tool" "$build_root/bin/$tool"
    strip -x "$build_root/bin/$tool"
    codesign --force --sign - "$build_root/bin/$tool"
done
cp "$src/COPYING.LGPLv2.1" "$src/LICENSE.md" "$build_root/licenses/"
