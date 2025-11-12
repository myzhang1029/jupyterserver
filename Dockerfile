# Needs --cap-add=CAP_MKNOD to build
FROM ubuntu:latest AS build

WORKDIR /tmp
ENV DISTR=plucky
ENV WOLFRAM_ENGINE="http://archive.raspberrypi.com/debian/pool/main/w/wolfram-engine/wolfram-engine_14.3.0+202510021899_arm64.deb"
ENV WOLFRAM_PACLET="https://github.com/WolframResearch/WolframLanguageForJupyter/releases/download/v0.9.3/WolframLanguageForJupyter-0.9.3.paclet"

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y debootstrap curl unzip

# Download and fix the Wolfram Engine package
RUN curl -fsSLo wolfram-engine-orig.deb "$WOLFRAM_ENGINE"
RUN dpkg-deb -R wolfram-engine-orig.deb wolfram-engine
# Extract the line number of the Depends line
RUN grep -n ^Depends: wolfram-engine/DEBIAN/control | cut -f1 -d: > lineno
# Correct dependencies
RUN sed -i "$(cat lineno)s/libwayland-egl1/libwayland-egl1, libegl1/;$(cat lineno)s/libasound2/libasound2t64/" wolfram-engine/DEBIAN/control
RUN dpkg-deb -z0 -Snone -Znone -b wolfram-engine wolfram-engine.deb
# Extract deps for debootstrap
RUN sed "$(cat lineno)q;d" wolfram-engine/DEBIAN/control | cut -f2- -d: | tr -d ' ' > wolfram-deps

RUN debootstrap --merged-usr --arch=arm64 \
    --include="ca-certificates,iproute2,iputils-ping,less,xxd,git,vim,curl,g++,pandoc,texlive-xetex,texlive-fonts-recommended,texlive-plain-generic,$(cat wolfram-deps)" \
    --variant=minbase \
    --components=main,universe "$DISTR" /target

# You should agree to the Wolfram Engine license before using this software
RUN echo Name: shared/accepted-wolfram-eula >> /target/var/cache/debconf/config.dat
RUN echo Template: shared/accepted-wolfram-eula >> /target/var/cache/debconf/config.dat
RUN echo Value: true >> /target/var/cache/debconf/config.dat
RUN echo Owners: wolfram-engine >> /target/var/cache/debconf/config.dat
RUN echo Flags: seen >> /target/var/cache/debconf/config.dat
RUN dpkg --root /target --install ./wolfram-engine.deb

RUN apt-mark -o Dir=/target auto $(cat wolfram-deps | tr , ' ')
RUN apt-get -o Dir=/target clean

# Prepare jupyter user
RUN echo "jupyter:x:1000:1000::/home/jupyter:/bin/sh" >> /target/etc/passwd
RUN echo "jupyter:!:::::::" >> /target/etc/shadow
RUN echo "jupyter:x:1000:" >> /target/etc/group
RUN mkdir /target/home/jupyter
RUN chown 1000:1000 /target/home/jupyter

# Pre-unpack the Wolfram kernel to the target
RUN curl --proto '=https' --tlsv1.2 -fsSLo WolframLanguageForJupyter.paclet "$WOLFRAM_PACLET"
RUN mkdir -p /target/home/jupyter/.Mathematica/Paclets/Repository
RUN unzip -d /target/home/jupyter/.Mathematica/Paclets/Repository WolframLanguageForJupyter.paclet
RUN chown -R 1000:1000 /target/home/jupyter/.Mathematica

FROM scratch as stage1

COPY --from=build /target /

ENV CARGO_HOME=/home/jupyter/.cargo
ENV RUSTUP_HOME=/home/jupyter/.rustup
ENV JULIAUP_INSTALLATION_PATH=/home/jupyter/.juliaup
ENV CONDA_INSTALLATION_PATH=/home/jupyter/.conda
ENV PATH="/home/jupyter/.juliaup/bin:/home/jupyter/.cargo/bin:/home/jupyter/.conda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
ENV MINIFORGE="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-aarch64.sh"

RUN usermod -aG video jupyter
USER jupyter
WORKDIR /home/jupyter

# Install conda in the second stage to make sure the shebang paths are correct
RUN curl --proto '=https' --tlsv1.2 -fsSLo /tmp/Miniforge3.sh "$MINIFORGE"
RUN bash /tmp/Miniforge3.sh -b -p "$CONDA_INSTALLATION_PATH"
RUN rm /tmp/Miniforge3.sh
RUN conda init
RUN conda install python mamba jupyterlab \
    matplotlib seaborn numpy pandas scipy sympy pillow \
    jupyter-collaboration jupyterlab-variableinspector jupyterlab_execute_time jupyter-resource-usage jupyterlab-katex \
    ipympl xeus-cpp r r-irkernel nbconvert
RUN mkdir "$CONDA_INSTALLATION_PATH/builtin-envs"
COPY conda-envs/quantum.yml "$CONDA_INSTALLATION_PATH/builtin-envs/quantum.yml"
RUN conda env create --file "$CONDA_INSTALLATION_PATH/builtin-envs/quantum.yml" --prefix "$CONDA_INSTALLATION_PATH/builtin-envs/quantum"
RUN "$CONDA_INSTALLATION_PATH/builtin-envs/quantum/bin/python" -m ipykernel install --prefix "$CONDA_INSTALLATION_PATH" --name quantum-python --display-name "Quantum Python"
RUN conda clean --all --yes

USER root
RUN echo "$CONDA_INSTALLATION_PATH/lib" > /etc/ld.so.conf.d/conda.conf
RUN ldconfig
RUN setcap CAP_NET_BIND_SERVICE=ep "$(realpath "$CONDA_INSTALLATION_PATH/bin/python")"
USER jupyter

# Kernel initialization steps for additional languages
## Rust
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain nightly --profile minimal
RUN cargo install --locked evcxr_jupyter
RUN evcxr_jupyter --install
## Julia
RUN curl --proto '=https' --tlsv1.2 -fsSL https://install.julialang.org | sh -s -- -y --path "$JULIAUP_INSTALLATION_PATH"
RUN julia -e 'using Pkg; Pkg.add("IJulia")'
## R
RUN R -e 'IRkernel::installspec(); IRkernel::installspec()'
## Wolfram
COPY mathematica.json $CONDA_INSTALLATION_PATH/share/jupyter/kernels/mathematica/kernel.json
# running Wolfram Kernel requires Raspberry Pi's `/dev/vcio`.

FROM scratch

COPY --from=stage1 / /

ENV CARGO_HOME=/home/jupyter/.cargo
ENV RUSTUP_HOME=/home/jupyter/.rustup
ENV PATH="/home/jupyter/.juliaup/bin:/home/jupyter/.cargo/bin:/home/jupyter/.conda/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

RUN echo "PATH='$PATH'" > /etc/environment
RUN echo "CARGO_HOME='$CARGO_HOME'" >> /etc/environment
RUN echo "RUSTUP_HOME='$RUSTUP_HOME'" >> /etc/environment

CMD ["/opt/conda/bin/jupyter", "lab"]
