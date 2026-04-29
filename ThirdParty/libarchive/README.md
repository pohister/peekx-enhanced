# libarchive

This directory vendors libarchive 3.8.7 for the PeekX Quick Look extension.

Contents:

- `lib/libarchive.a`: universal `arm64` + `x86_64` static library
- `include/archive.h` and `include/archive_entry.h`: public C headers
- `licenses/COPYING`: upstream license

The library was built from the official `v3.8.7` release with:

```sh
cmake -S libarchive-3.8.7 -B build-universal \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES='arm64;x86_64' \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
  -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_TEST=OFF \
  -DENABLE_TAR=OFF \
  -DENABLE_CPIO=OFF \
  -DENABLE_CAT=OFF \
  -DENABLE_OPENSSL=OFF \
  -DENABLE_MBEDTLS=OFF \
  -DENABLE_NETTLE=OFF \
  -DENABLE_ZSTD=OFF \
  -DENABLE_LZ4=OFF \
  -DENABLE_LZO=OFF \
  -DENABLE_EXPAT=OFF \
  -DENABLE_LIBB2=OFF \
  -DENABLE_PCREPOSIX=OFF \
  -DENABLE_ACL=OFF \
  -DENABLE_XATTR=OFF \
  -DENABLE_ICONV=ON \
  -DENABLE_LIBXML2=ON

cmake --build build-universal --target archive_static
```

The extension links the static library plus system compression/XML libraries
provided by the macOS SDK.
