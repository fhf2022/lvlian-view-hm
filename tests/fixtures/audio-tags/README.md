# Synthetic audio tag fixtures

These three 0.12-second silent audio files contain the same generated blue PNG
cover and UTF-8 tags (`LinkFiles blue`, `Synthetic Artist`, `Artwork QA`). They
are small, valid encoded media files; no user audio or copyrighted recording is
included. Tests do not require ffmpeg or files from the ignored `temp/` folder.

The fixtures were generated with ffmpeg using a silent stereo source, an attached
PNG, and MP3/libmp3lame, FLAC/flac and M4A/aac encoders. Tests additionally build
large-cover, tail-atom, malformed-header and alternate text-encoding cases in
memory so those cases do not inflate the repository.
