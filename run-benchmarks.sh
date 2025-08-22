#!/bin/bash


# Range dei parametri
OLD_SPACE_VALUES=(16 32 48 64 80 96 112 128 144 160 176 192 208 224 240 256 272 288 304 320 336 352 368 384 400 416 432 448 464 480 496 512 528 544 560 576 592 608 624 640 656 672 688 704 720 736 752 768 784 800 816 832 848 864 880 896 912 928 944 960 976 992 1008 1024)
SEMI_SPACE_VALUES=(16 32 48 64 80 96 112 128 144 160 176 192 208 224 240 256 272 288 304 320 336 352 368 384 400 416 432 448 464 480 496 512 528 544 560 576 592 608 624 640 656 672 688 704 720 736 752 768 784 800 816 832 848 864 880 896 912 928 944 960 976 992 1008 1024)
# OLD_SPACE_VALUES=(256)
# SEMI_SPACE_VALUES=(256)
# TODO: increase dei valori


# Nome dell'immagine Docker già buildata
IMAGE_NAME="web-tooling-benchmark"


# Cartella per i risultati
RESULTS_DIR="./version_1.0_results"
mkdir -p "$RESULTS_DIR"


for OLD in "${OLD_SPACE_VALUES[@]}"; do
  for SEMI in "${SEMI_SPACE_VALUES[@]}"; do
    FILE_NAME="$RESULTS_DIR/old${OLD}_semi${SEMI}.txt"


    if [ -f "$FILE_NAME" ]; then
      echo "[SKIP] Già eseguito old=$OLD semi=$SEMI"
      continue
    fi


    echo "[RUN] old=$OLD semi=$SEMI"
    docker run --rm \
      -e NODE_OPTIONS="--max-old-space-size=$OLD --max-semi-space-size=$SEMI" \
      "$IMAGE_NAME" \
      npm run benchmark > "$FILE_NAME" 2>&1
      # npm run build -- --env.only  && npm run benchmark > "$FILE_NAME" 2>&1
      # npm run build  && npm run benchmark > "$FILE_NAME" 2>&1
  done
done


echo "✅ Tutti i benchmark completati. Risultati in: $RESULTS_DIR"