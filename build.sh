#!/usr/bin/env bash

# TODO: https://emscripten.org/docs/porting/Debugging.html
set -xeu

PHP_VERSION=7.4.33
PHP_PATH=php-$PHP_VERSION
AST_PATH=ast-1.1.2
TAINT_CHECK_PATH=phan-taint-check-plugin
# Use a standalone version of ace to prevent noise with CSP etc.
ACE_VERSION=1.36.2
ACE_PATH=ace-builds

if ! type emconfigure 2>/dev/null >/dev/null ; then
    echo "emconfigure not found. Install emconfigure and add it to your path (e.g. source emsdk/emsdk_env.sh)"
    exit 1
fi

echo "Check PHP source"
if [ ! -d $PHP_PATH ]; then
    if [ ! -e $PHP_PATH.tar.xz ]; then
        echo "Get PHP source"
        wget https://www.php.net/distributions/$PHP_PATH.tar.xz
    fi
	echo "Extract PHP source"
    tar xf $PHP_PATH.tar.xz
fi

echo "Apply error handler patch"
cp main.c $PHP_PATH/main/

echo "Check ast"
if [ ! -d "$PHP_PATH/ext/ast"  ]; then
    if [ ! -f "$AST_PATH.tgz" ]; then
        echo "Get ast"
        wget https://pecl.php.net/get/$AST_PATH.tgz -O $AST_PATH.tgz
    fi
    tar zxf $AST_PATH.tgz
    mv "$AST_PATH" "$PHP_PATH/ext/ast"
fi

echo "Verify taint-check"
if [ ! -e $TAINT_CHECK_PATH ]; then
    echo "Please install phan-taint-check to $TAINT_CHECK_PATH"
    exit 1
fi

echo "Generating taint-check phar"
cd $TAINT_CHECK_PATH

./internal/make_phar.sh
# Check that the phar is not corrupt
php ./build/taint-check.phar --version || exit 1

cd ..
cp $TAINT_CHECK_PATH/build/taint-check.phar $PHP_PATH/

echo "Verify ace editor"
if [ ! -e $ACE_PATH ]; then
    echo "Pull ace editor"
    wget https://github.com/ajaxorg/ace-builds/archive/v$ACE_VERSION.tar.gz -O $ACE_PATH.tar.gz
    tar zxf $ACE_PATH.tar.gz
    # Make it version-agnostic
    mv ace-builds-$ACE_VERSION ace-builds
fi

echo "Configure"

# https://emscripten.org/docs/porting/Debugging.html
# -g4 can be used to generate source maps for debugging C crashes
# NOTE: If -g4 is used, then firefox can require a lot of memory to load the resulting file.
export CFLAGS='-O3 -DZEND_MM_ERROR=0'
cd $PHP_PATH

# TODO Can we avoid rebuilding if already done?

# Configure this with a minimal set of extensions, statically compiling the third-party ast library.
# Run buildconf so that ast will a valid configure option
./buildconf --force

set +e
emconfigure ./configure \
  --disable-all \
  --disable-cgi \
  --disable-cli \
  --disable-rpath \
  --disable-phpdbg \
  --with-valgrind=no \
  --without-pear \
  --without-valgrind \
  --without-pcre-jit \
  --with-layout=GNU \
  --enable-ast \
  --enable-bcmath \
  --enable-ctype \
  --enable-embed=static \
  --enable-filter \
  --enable-json \
  --enable-phar \
  --enable-mbstring \
  --disable-mbregex \
  --disable-fiber-asm \
  --enable-tokenizer

if [ $? -ne 0 ]; then
    cat config.log
    exit 1
fi

set -e

echo "Build"
# -j5 seems to work for parallel builds
emmake make clean

# NOTE: On toolforge, this might fail when compiling parse_date.c, probably due to limited resources.
#  Debug failures with export EMCC_DEBUG=1; emmake make -j5 VERBOSE=1
emmake make -j5

rm -rf out
mkdir -p out

# Package taint-check separately since the PHP license is incompatible with GPL
sh $EMSDK/upstream/emscripten/tools/file_packager out/taint-check.data --preload taint-check.phar --js-output=out/taint-check.js --export-name='PHP'

emcc $CFLAGS -I . -I Zend -I main -I TSRM/ ../pib_eval.c -c -o pib_eval.o
# NOTE: If this crashes with code 16, ASSERTIONS=1 is useful
# -s IMPORTED_MEMORY=1 may help reduce memory if emscripten 3.0.10 is used?
emcc $CFLAGS \
  --llvm-lto 2 \
  -s ENVIRONMENT=web \
  -s EXPORTED_FUNCTIONS='["_pib_eval", "_php_embed_init", "_zend_eval_string", "_php_embed_shutdown"]' \
  -s EXTRA_EXPORTED_RUNTIME_METHODS='["ccall"]' \
  -s MODULARIZE=1 \
  -s EXPORT_NAME="'PHP'" \
  -s TOTAL_MEMORY=134217728 \
  -s ASSERTIONS=0 \
  -s INVOKE_RUN=0 \
  -s FORCE_FILESYSTEM=1 \
  -s ERROR_ON_UNDEFINED_SYMBOLS=0 \
  --pre-js out/taint-check.js \
  libs/libphp7.a pib_eval.o -o out/php.js

cp out/php.* out/taint-check.{js,data} ..

cd ..

mkdir -p html
cp -r index.html php.{js,wasm} taint-check.{js,data} static $ACE_PATH html/
if [[ -f php.data ]]; then
    # This file stopped being necessary somewhere between emscripten 2.0.9 and 2.0.20
    cp php.data html/
fi

echo "Done"
