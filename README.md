Travis uses Ubuntu 14.04 (trusty)
http://packages.ubuntu.com/trusty/

dpkg -S /usr/lib/x86_64-linux-gnu/libclang-3.7.so.1
libclang1-3.7:amd64: /usr/lib/x86_64-linux-gnu/libclang-3.7.so.1

dpkg -S /usr/lib/x86_64-linux-gnu/libLLVM-3.7.so.1
libllvm3.7:amd64: /usr/lib/x86_64-linux-gnu/libLLVM-3.7.so.1

The download from Clang is compiled for trusty.
clang+llvm-3.7.1-x86_64-linux-gnu-ubuntu-14.04.tar.xz
The following files has been copied.
./lib/libclang.so -> libclang.so.3.7
