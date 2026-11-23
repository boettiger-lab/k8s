# Trivy ignore policy for .github/workflows/image-scan.yml.
# Keep this list short and give each entry a reason.
package trivy

default ignore = false

# Kernel headers. Containers run on the host's kernel, so CVEs in the image's
# copy of the kernel headers do not apply. Patch the nodes' kernels instead.
ignore {
	input.PkgName == "linux-libc-dev"
}
