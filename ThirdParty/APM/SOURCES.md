# Pinned APM sources

- webrtc-audio-processing 2.1
  - URL: https://gstreamer.freedesktop.org/data/src/mirror/webrtc-audio-processing/webrtc-audio-processing-2.1.tar.xz
  - SHA-256: ae9302824b2038d394f10213cab05312c564a038434269f11dbf68f511f9f9fe
- abseil-cpp 20240722.0
  - URL: https://github.com/abseil/abseil-cpp/releases/download/20240722.0/abseil-cpp-20240722.0.tar.gz
  - SHA-256: f50e5ac311a81382da7fa75b97310e4b9006474f9560ac46f54a9967f07d4ae3
- Abseil Meson wrap patch abseil-cpp_20240722.0-3
  - URL: https://wrapdb.mesonbuild.com/v2/abseil-cpp_20240722.0-3/get_patch
  - SHA-256: 12dd8df1488a314c53e3751abd2750cf233b830651d168b6a9f15e7d0cf71f7b

The build uses Meson 1.11.2, Ninja 1.13.2, `MACOSX_DEPLOYMENT_TARGET=14.2`, and `meson setup --default-library=static --buildtype=release --wrap-mode=forcefallback -Dcpp_std=c++17`. Static archives stay in `.build/apm/lib`. Upstream source stays under `$TMPDIR/meetingtape-apm-v2.1`.
