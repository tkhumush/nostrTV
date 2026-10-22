# Separate audio/video HLS test fixture

Six seconds of a synthetic test pattern and a 440 Hz tone, generated locally with
FFmpeg. No third-party footage. The master advertises video-only segments and a
separate default AAC audio rendition. `SplitHLSPlaybackTests` serves it on a
temporary loopback port and checks video decoding, audio selection and requests
for both sets of segments.

Generate from the repository root (FFmpeg 8):

```sh
ffmpeg -f lavfi -i 'testsrc2=size=160x90:rate=12' \
  -f lavfi -i 'sine=frequency=440:sample_rate=48000' -t 6 \
  -map 0:v -map 1:a -c:v libx264 -preset ultrafast -pix_fmt yuv420p \
  -b:v 80k -g 24 -c:a aac -b:a 32k -f hls -hls_time 2 -hls_playlist_type vod \
  -var_stream_map 'v:0,agroup:aud a:0,agroup:aud,default:yes,language:eng' \
  -master_pl_name cove-split-master.m3u8 \
  -hls_segment_filename 'nostrTVTests/MediaFixtures/cove-split-%v-%d.ts' \
  'nostrTVTests/MediaFixtures/cove-split-%v.m3u8'
```

Append `.bin` to the generated `.ts` filenames so Xcode copies them as resources
rather than treating them as TypeScript. The fixture server strips that packaging
suffix. The playlists retain their normal `.ts` URLs. These files belong only to
the test target, never the shipping application.
