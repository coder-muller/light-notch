#!/bin/bash
# Build do LightNotch sem projeto Xcode: swiftc -> .app montado à mão -> codesign ad-hoc.
# Uso: ./build.sh [build|run|install|clean]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="LightNotch"
BUNDLE_ID="com.guilherme.lightnotch"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$NAME.app"
INSTALL_PATH="/Applications/$NAME.app"

build() {
    local sources=()
    while IFS= read -r file; do sources+=("$file"); done < <(find "$ROOT/Sources" -name '*.swift' | sort)
    if [[ ${#sources[@]} -eq 0 ]]; then
        echo "erro: nenhum arquivo .swift em $ROOT/Sources" >&2
        exit 1
    fi

    plutil -lint "$ROOT/Resources/Info.plist" >/dev/null

    rm -rf "$APP"
    mkdir -p "$APP/Contents/MacOS"

    echo "==> Compilando ${#sources[@]} arquivo(s) Swift"
    swiftc -O -wmo \
        -swift-version 5 \
        -target arm64-apple-macos14.0 \
        -Xlinker -dead_strip \
        "${sources[@]}" \
        -o "$APP/Contents/MacOS/$NAME"

    # Remove a tabela de símbolos (seguro para Swift: a reflexão usa seções próprias, não símbolos).
    # Precisa vir antes do codesign, pois strip invalida a assinatura.
    strip "$APP/Contents/MacOS/$NAME"

    cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

    # Ícone gerado por código (scripts/make-icon.swift); só é refeito quando o script muda.
    local icon="$BUILD_DIR/AppIcon.icns"
    if [[ ! -f "$icon" || "$ROOT/scripts/make-icon.swift" -nt "$icon" ]]; then
        echo "==> Gerando ícone"
        swift "$ROOT/scripts/make-icon.swift" "$icon"
    fi
    mkdir -p "$APP/Contents/Resources"
    cp "$icon" "$APP/Contents/Resources/AppIcon.icns"

    # Assinatura ad-hoc com requisito designado FIXO (só o identificador do bundle):
    # o TCC/Automação reconhece o app entre rebuilds e não pergunta de novo.
    # Sem hardened runtime (sem --options runtime).
    echo "==> Assinando (ad-hoc, requisito designado fixo)"
    codesign --force --sign - \
        -r="designated => identifier \"$BUNDLE_ID\"" \
        "$APP"
    codesign --verify --deep --strict "$APP"
    codesign -d -r- "$APP" 2>&1 | grep '^designated' || true

    local bytes
    bytes=$(stat -f%z "$APP/Contents/MacOS/$NAME")
    echo "==> Pronto: $APP"
    echo "    binário: $(( (bytes + 512) / 1024 )) KB ($bytes bytes)"
}

quit_app() {
    pkill -x "$NAME" || true
    # pkill não espera: sem isto o `open` pode reativar a instância que está saindo (erro -600).
    while pgrep -x "$NAME" >/dev/null; do sleep 0.1; done
}

case "${1:-build}" in
    build)
        build
        ;;
    run)
        build
        quit_app
        open "$APP"
        ;;
    install)
        build
        quit_app
        rm -rf "$INSTALL_PATH"
        ditto "$APP" "$INSTALL_PATH"
        open "$INSTALL_PATH"
        echo "==> Instalado em $INSTALL_PATH"
        ;;
    clean)
        rm -rf "$BUILD_DIR"
        echo "==> build/ removido"
        ;;
    *)
        echo "uso: $0 [build|run|install|clean]" >&2
        exit 2
        ;;
esac
