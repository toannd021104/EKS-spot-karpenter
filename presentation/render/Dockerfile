# Render image for the deck: pptx -> pdf (LibreOffice) -> png (poppler).
# Build: docker build -t finops-deck-render presentation/render
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libreoffice-impress poppler-utils fonts-liberation fonts-dejavu-core fontconfig \
 && rm -rf /var/lib/apt/lists/*
RUN useradd -m -u 1000 render
USER render
WORKDIR /work
