FROM ocaml/opam:debian-10-ocaml-4.12

USER root

RUN apt-get update && apt-get -y upgrade
RUN apt-get install -y build-essential rsync git libpcre3-dev libncurses-dev pkg-config m4 unzip aspcud autoconf bubblewrap
RUN apt-get install -y libssl-dev libgmp-dev libffi-dev libeccodes-dev libcurl4-gnutls-dev
RUN apt-get install -y python3 python3-boto3

RUN opam init -y
RUN eval $(opam env) && opam install "core=v0.14.1" async ctypes ctypes-foreign ocurl dune

RUN mkdir /tawhiri-downloader
ADD *.ml *.mli dune* *.py /tawhiri-downloader/
WORKDIR /tawhiri-downloader

RUN eval $(opam env) && dune build --profile=release main.exe

RUN mkdir -p /srv/tawhiri-datasets

CMD ["/tawhiri-downloader/_build/default/main.exe", "daemon"]