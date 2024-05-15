#!/bin/bash
# README: https://gist.github.com/shoreline-chrism/1f1f901d0892b4ba5cd14cafb1000976#file-optimize-images-md
# Inspiration: https://gist.github.com/julianxhokaxhiu/c0a8e813eabf9d6d9873

# Check to make sure pngquant and jpegoptim are installed by running each command. If not installed, run
# sudo apt-get install imagemagick pngquant jpegoptim

# Optional default values for optional flags
DIR=false
MAXQUALITY="60"
CONVERTPNG=false
CONVERTWEBP=false

while getopts 'd:q:cw' c; 
do
  case $c in
    d) DIR="$OPTARG" ;;
    q) MAXQUALITY="$OPTARG" ;;
    c) CONVERTPNG=true ;;
    w) CONVERTWEBP=true ;; # Convert PNGs to WEBP
  esac
done

if [ "$DIR" == false ]; then
  echo "Include a directory with -d"; exit 1;
fi

# Convert fake jpgs to jpgs (files that are actually png but have .jpg filename)
# Use imagemagicks convert command
find "$DIR" \( -iname "*.jpg" -o -iname "*.jpeg" \) -type f -exec bash -c '[[ "$( file -bi "$1" )" == *image/png* ]]' bash {} \; -exec convert {} {} \;

if [ "$CONVERTPNG" != false ]; then
  # Convert actual PNGs to JPGs
  echo "Converting actual PNGs files to JPG"
  find "$DIR" -type f -name "*.png" | sed 's/\.png$//' | xargs -I% convert -quality "$MAXQUALITY" "%.png" "%.jpg"
  find "$DIR" -type f -name "*.png" -exec rm {} +
fi

if [ "$CONVERTWEBP" != false ]; then
  # Convert PNGs to WEBP
  echo "Converting actual PNGs files to WebP"
  find "$DIR" -type f -name "*.png" | sed 's/\.png$//' | xargs -I% convert "%.png" "%.webp"
  # find "$DIR" -type f -name "*.png" -exec rm {} +
fi

# Optimize PNGs
find "$DIR" -type f -iname "*.png" -exec pngquant -f --ext .png --verbose --quality 0-"$MAXQUALITY" -s 1 -- {} \;

# Optimize JPGs
find "$DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) -exec jpegoptim -m"$MAXQUALITY" -f --strip-all {} \;
