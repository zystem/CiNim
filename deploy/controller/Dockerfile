# The image of the job controller of an organisation (SHD-007): the controller and the shim that it puts into every step Pod, both static.
# Build the context with tools/image/build_controller.sh. The Kubernetes client reads the CA of the cluster from the Pod's ServiceAccount.
FROM scratch
COPY controller-static /controller
COPY cicd-shim /cicd-shim
ENV CINIM_SHIM_BIN=/cicd-shim
USER 65532:65532
ENTRYPOINT ["/controller"]
