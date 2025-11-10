# Needs --cap-add=CAP_MKNOD to build
FROM ubuntu:latest AS build

WORKDIR /tmp
ENV DISTR=plucky
ENV WOLFRAM_ENGINE="http://archive.raspberrypi.com/debian/pool/main/w/wolfram-engine/wolfram-engine_14.3.0+202510021899_arm64.deb"

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y debootstrap curl

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

FROM scratch

COPY --from=build /target /

ENV CARGO_HOME=/opt/cargo
ENV RUSTUP_HOME=/opt/rustup
ENV JULIA_INSTALLATION_PATH=/opt/julia
ENV CONDA_INSTALLATION_PATH=/opt/conda
ENV PATH="/opt/cargo/bin:/opt/julia/bin:/opt/conda/bin:$PATH"
ENV MINIFORGE="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-aarch64.sh"
ENV WOLFRAM_PACLET="https://github.com/WolframResearch/WolframLanguageForJupyter/releases/download/v0.9.3/WolframLanguageForJupyter-0.9.3.paclet"

RUN echo "PATH='$PATH'" >> /etc/profile
RUN echo "CARGO_HOME='$CARGO_HOME'" >> /etc/profile
RUN echo "RUSTUP_HOME='$RUSTUP_HOME'" >> /etc/profile

# Install conda here to make sure the shebang paths are correct
RUN curl -fsSLo /tmp/Miniforge3.sh "$MINIFORGE"
RUN bash /tmp/Miniforge3.sh -b -p "$CONDA_INSTALLATION_PATH"
RUN rm /tmp/Miniforge3.sh
RUN conda install python mamba jupyterlab \
    matplotlib seaborn numpy pandas scipy sympy pillow \
    jupyter-collaboration jupyterlab-variableinspector jupyterlab_execute_time jupyter-resource-usage jupyterlab-katex \
    ipympl xeus-cpp r r-irkernel nbconvert
RUN conda clean --all --yes
RUN echo "$CONDA_INSTALLATION_PATH/lib" > /etc/ld.so.conf.d/conda.conf
RUN ldconfig
RUN setcap CAP_NET_BIND_SERVICE=+eip "$(realpath "$CONDA_INSTALLATION_PATH/bin/python")"

# Kernel initialization steps for additional languages
## Rust
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain nightly --profile minimal
RUN cargo install --locked evcxr_jupyter
RUN evcxr_jupyter --install
## Julia
RUN curl --proto '=https' --tlsv1.2 -fsSL https://install.julialang.org | sh -s -- -y --path "$JULIA_INSTALLATION_PATH"
RUN julia -e 'using Pkg; Pkg.add("IJulia")'
## R
RUN R -e 'IRkernel::installspec(); IRkernel::installspec(user = FALSE)'

USER jupyter
WORKDIR /home/jupyter

RUN curl -fsSLo /home/jupyter/WolframLanguageForJupyter.paclet "$WOLFRAM_PACLET"
# Wolfram Kernel requires Raspberry Pi's `/dev/vcio`.
# The kernel must be manually installed
# ```
# PacletInstall["/home/jupyter/WolframLanguageForJupyter.paclet"]
# Needs["WolframLanguageForJupyter`"]
# ConfigureJupyter["Add", "JupyterInstallation" -> "/opt/conda/bin/jupyter"]
# ```

CMD ["/opt/conda/bin/jupyter", "lab"]
