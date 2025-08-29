#!/bin/bash

# Range dei parametri
OLD_SPACE_VALUES=(16 32 48 64 80 96 112 128 144 160 176 192 208 224 240 256 272 288 304 320 336 352 368 384 400 416 432 448 464 480 496 512 528 544 560 576 592 608 624 640 656 672 688 704 720 736 752 768 784 800 816 832 848 864 880 896 912 928 944 960 976 992 1008 1024)
SEMI_SPACE_VALUES=(16 32 48 64 80 96 112 128 144 160 176 192 208 224 240 256 272 288 304 320 336 352 368 384 400 416 432 448 464 480 496 512 528 544 560 576 592 608 624 640 656 672 688 704 720 736 752 768 784 800 816 832 848 864 880 896 912 928 944 960 976 992 1008 1024)

# Nome dell'immagine Docker già buildata
IMAGE_NAME="web-tooling-benchmark"

# Cartella per i risultati
RESULTS_DIR="./version_1.1_results"
APP_VALUES=("acorn" "babel" "babel-minify" "babylon" "buble" "chai" "coffeescript" "espree" "esprima" "jshint" "lebab" "postcss" "prepack" "prettier" "source-map" "terser" "typescript" "uglify-js")

mkdir -p "$RESULTS_DIR"

FAIL_LOG="$RESULTS_DIR/failures.log"
> "$FAIL_LOG"  # resetta il file a inizio esecuzione

for APP in "${APP_VALUES[@]}"; do
  mkdir -p "$RESULTS_DIR/$APP"

  for OLD in "${OLD_SPACE_VALUES[@]}"; do
    for SEMI in "${SEMI_SPACE_VALUES[@]}"; do
      FILE_NAME="$RESULTS_DIR/${APP}/old${OLD}_semi${SEMI}.txt"

      if [ -f "$FILE_NAME" ]; then
        echo "[SKIP] Già eseguito $APP old=$OLD semi=$SEMI"
        continue
      fi

      echo "[RUN] $APP old=$OLD semi=$SEMI"

      # esegui docker
      if docker run --rm \
        -e NODE_OPTIONS="--max-old-space-size=$OLD --max-semi-space-size=$SEMI" \
        "$IMAGE_NAME" \
        /bin/bash -c "npm run build -- --env.only $APP" \
        npm run benchmark -- --only "$APP" \
        > "$FILE_NAME" 2>&1; then
        echo "[OK] $APP old=$OLD semi=$SEMI"
      else
        echo "[FAIL] $APP old=$OLD semi=$SEMI"
        echo "$APP old=$OLD semi=$SEMI" >> "$FAIL_LOG"
      fi
    done
  done
done

echo "✅ Tutti i benchmark completati."
echo "📁 Risultati in: $RESULTS_DIR"
echo "❎ Fallimenti salvati in: $FAIL_LOG"
