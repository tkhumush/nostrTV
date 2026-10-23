# Phone playback fixture

`cove.mp4` is a locally generated test pattern with a silent AAC track. It is a
UI-test resource, never an app resource. The UI test runner serves it over a
loopback-only HTTP listener; no relay connection, identity, invoice, or payment
is used. It lets the fold/rotation tests check a real AVPlayer clock.

Regenerate with FFmpeg:

```sh
ffmpeg -f lavfi -i 'testsrc2=size=160x90:rate=12' \
  -f lavfi -i 'anullsrc=r=48000:cl=stereo' -t 180 \
  -c:v libx264 -preset ultrafast -crf 35 -pix_fmt yuv420p \
  -c:a aac -b:a 16k -movflags +faststart \
  CoveIOSUITests/MediaFixtures/cove.mp4
```
