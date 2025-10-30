# Needs --cap-add=CAP_MKNOD to build
FROM ubuntu:latest AS build

WORKDIR /tmp
ENV DISTR=plucky
ENV MINIFORGE="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-aarch64.sh"
ENV WOLFRAM_ENGINE="https://files.wolframcdn.com/raspbian/14.2.1.0/wolfram-engine_14.2.1%2B202504031673_arm64.deb"
ENV WOLFRAM_PACLET="https://github.com/WolframResearch/WolframLanguageForJupyter/releases/download/v0.9.3/WolframLanguageForJupyter-0.9.3.paclet"

RUN apt-get update
RUN DEBIAN_FRONTEND=noninteractive apt-get install -y debootstrap curl
RUN debootstrap --merged-usr --arch=arm64 \
    --include=git,vim,curl,g++,pandoc,texlive-xetex \
    --exclude=ubuntu-minimal,ubuntu-pro-client,ubuntu-pro-client-l10n,netplan.io,python3-netplan,libnetplan1,netplan-generator,eject,systemd-resolved,systemd-timesyncd,networkd-dispatcher,rsyslog,keyboard-configuration \
    --components=main,universe "$DISTR" /target

RUN curl -fsSLo /target/var/tmp/Miniforge3.sh "$MINIFORGE"
RUN curl -fsSLo /target/var/tmp/WolframLanguageForJupyter.paclet "$WOLFRAM_PACLET"

RUN curl -fsSLo wolfram-engine-orig.deb "$WOLFRAM_ENGINE"
RUN dpkg-deb -R wolfram-engine-orig.deb wolfram-engine
RUN grep -n ^Depends: wolfram-engine/DEBIAN/control|cut -f1 -d: > lineno
RUN sed -i "$(cat lineno)s/libwayland-egl1-mesa/libwayland-egl1, libegl1/;$(cat lineno)s/libasound2/libasound2t64/" wolfram-engine/DEBIAN/control
RUN dpkg-deb -b wolfram-engine /target/var/tmp/wolfram-engine.deb


FROM scratch

COPY --from=0 /target/. /

RUN bash /var/tmp/Miniforge3.sh -b -p /opt/conda
RUN rm /var/tmp/Miniforge3.sh
RUN /opt/conda/bin/conda install python mamba jupyterlab matplotlib seaborn numpy scipy pandas pillow jupyter-collaboration jupyterlab-variableinspector jupyterlab_execute_time jupyter-resource-usage jupyterlab-katex ipympl xeus-cling evcxr nbconvert nbconvert-webpdf
RUN /opt/conda/bin/conda clean --all --yes
RUN /opt/conda/bin/evcxr_jupyter --install

RUN curl -fsSL https://install.julialang.org | sh -s -- -y --path /opt/julia
RUN /opt/julia/bin/julia -e 'using Pkg; Pkg.add("IJulia")'

RUN yes | DEBIAN_FRONTEND=readline apt-get install -y /var/tmp/wolfram-engine.deb
RUN rm /var/tmp/wolfram-engine.deb

# Wolfram Kernel must be manually installed:
# ```
# PacletInstall["/var/tmp/WolframLanguageForJupyter.paclet"]
# Needs["WolframLanguageForJupyter`"]
# ConfigureJupyter["Add", "JupyterInstallation" -> "/opt/conda/bin/jupyter"]
# ```

RUN apt-get clean

CMD ["/opt/conda/bin/jupyter", "lab", "--allow-root"]
