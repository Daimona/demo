#!/bin/bash

echo "Get PHP source"
wget https://downloads.php.net/~cmb/php-7.3.0beta3.tar.xz
tar xf php-7.3.0beta3.tar.xz

echo "Get Phan phar"
wget https://github.com/phan/phan/releases/download/1.0.1/phan.phar -O phan-1.0.1.phar

echo "Apply patch"
patch -p0 -i mods.diff

echo "Configure"
cd php-7.3.0beta3
emconfigure ./configure \
  --disable-all \
  --disable-cgi \
  --disable-cli \
  --disable-rpath \
  --disable-phpdbg \
  --without-pear \
  --without-valgrind \
  --without-pcre-jit \
  --with-layout=GNU \
  --enable-embed=static \
  --enable-bcmath \
  --enable-json \
  --enable-ctype \
  --enable-tokenizer

echo "Build"
emmake make
mkdir out
emcc -O3 -I . -I Zend -I main -I TSRM/ ../pib_eval.c -o pib_eval.o
emcc -O3 \
  -s WASM=1 \
  -s ENVIRONMENT=web \
  -s EXPORTED_FUNCTIONS='["_pib_eval", "_php_embed_init", "_zend_eval_string", "_php_embed_shutdown"]' \
  -s EXTRA_EXPORTED_RUNTIME_METHODS='["ccall"]' \
  -s TOTAL_MEMORY=134217728 \
  -s ASSERTIONS=0 \
  -s INVOKE_RUN=0 \
  --preload-file Zend/bench.php \
  --preload-file phan-1.0.1.phar \
  libs/libphp7.a pib_eval.o -o out/php.html

cp out/php.wasm out/php.js out/php.data ..

echo "Done"
