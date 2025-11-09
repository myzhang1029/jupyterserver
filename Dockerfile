# Needs --cap-add=CAP_MKNOD to build
FROM ubuntu:latest AS build

WORKDIR /tmp
ENV DISTR=plucky
ENV MINIFORGE="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-aarch64.sh"
ENV WOLFRAM_ENGINE="http://archive.raspberrypi.com/debian/pool/main/w/wolfram-engine/wolfram-engine_14.3.0+202510021899_arm64.deb"
ENV WOLFRAM_PACLET="https://github.com/WolframResearch/WolframLanguageForJupyter/releases/download/v0.9.3/WolframLanguageForJupyter-0.9.3.paclet"

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y debootstrap curl

# Download and fix the Wolfram Engine package
RUN curl -fsSLo wolfram-engine-orig.deb "$WOLFRAM_ENGINE"
RUN dpkg-deb -R wolfram-engine-orig.deb wolfram-engine
# Extract the line number of the Depends line
RUN grep -n ^Depends: wolfram-engine/DEBIAN/control | cut -f1 -d: > lineno
# Correct dependencies
RUN sed -i "$(cat lineno)s/libasound2/libasound2t64/" wolfram-engine/DEBIAN/control
RUN dpkg-deb -b wolfram-engine wolfram-engine.deb
# Extract deps for debootstrap
RUN sed "$(cat lineno)q;d" wolfram-engine/DEBIAN/control | cut -f2- -d: | tr -d ' ' > wolfram-deps

RUN debootstrap --merged-usr --arch=arm64 \
    --include="ca-certificates,iproute2,iputils-ping,less,xxd,git,vim,curl,g++,pandoc,texlive-xetex,$(cat wolfram-deps)" \
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
RUN apt -o Dir=/target clean

RUN curl -fsSLo /target/var/tmp/Miniforge3.sh "$MINIFORGE"
RUN curl -fsSLo /target/var/tmp/WolframLanguageForJupyter.paclet "$WOLFRAM_PACLET"


FROM scratch

ENV PATH="/opt/cargo/bin:/opt/julia/bin:/opt/conda/bin:$PATH"
ENV CARGO_HOME=/opt/cargo
ENV RUSTUP_HOME=/opt/rustup
ENV JULIA_INSTALLATION_PATH=/opt/julia

COPY --from=0 /target/. /

RUN echo "PATH='$PATH'" >> /etc/profile
RUN echo "CARGO_HOME='$CARGO_HOME'" >> /etc/profile
RUN echo "RUSTUP_HOME='$RUSTUP_HOME'" >> /etc/profile

# Install conda here to make sure the shebang paths are correct
RUN bash /var/tmp/Miniforge3.sh -b -p /opt/conda
RUN rm /var/tmp/Miniforge3.sh
RUN /opt/conda/bin/conda install python mamba jupyterlab \
    matplotlib seaborn numpy pandas scipy sympy pillow \
    jupyter-collaboration jupyterlab-variableinspector jupyterlab_execute_time jupyter-resource-usage jupyterlab-katex \
    ipympl xeus-cpp r r-irkernel nbconvert nbconvert-webpdf nbconvert-qtpdf playwright
RUN /opt/conda/bin/conda clean --all --yes

# Kernel initialization steps for additional languages
## Rust
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain nightly --profile minimal
RUN "$CARGO_HOME"/bin/cargo install --locked evcxr_jupyter
RUN "$CARGO_HOME"/bin/evcxr_jupyter --install
## Julia
RUN curl --proto '=https' --tlsv1.2 -fsSL https://install.julialang.org | sh -s -- -y --path "$JULIA_INSTALLATION_PATH"
RUN "$JULIA_INSTALLATION_PATH"/bin/julia -e 'using Pkg; Pkg.add("IJulia")'
## R
RUN /opt/conda/bin/R -e 'IRkernel::installspec(); IRkernel::installspec(user = FALSE)'

# Wolfram Kernel requires Raspberry Pi's `/dev/vcio`.
# The kernel must be manually installed
# ```
# PacletInstall["/var/tmp/WolframLanguageForJupyter.paclet"]
# Needs["WolframLanguageForJupyter`"]
# ConfigureJupyter["Add", "JupyterInstallation" -> "/opt/conda/bin/jupyter"]
# ```

CMD ["/opt/conda/bin/jupyter", "lab", "--allow-root"]
