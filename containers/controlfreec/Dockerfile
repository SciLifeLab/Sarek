FROM nfcore/base:latest

LABEL \
  author="Maxime Garcia" \
  description="Control-FREEC image used in Sarek" \
  maintainer="maxime.garcia@scilifelab.se"

COPY environment.yml /

RUN \
  conda env create -f /environment.yml && \
  conda clean -a

  # Export PATH
ENV PATH /opt/conda/envs/sarek-controlfreec-2.0/bin:$PATH
