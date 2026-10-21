# bash 5.2 syntax: runs inside the sandbox container (see docs/bash-style.md).
# ca.sh: writes $HOME/.ca-bundle.pem, the image's own CA bundle followed by
# the extra CA certificates mounted at /chalk-ca.pem (CHALK_EXTRA_CA_CERTS).
set -e
out="$HOME/.ca-bundle.pem"
: > "$out"
for system in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
  if [ -f "$system" ]; then
    cat "$system" >> "$out"
    break
  fi
done
cat /chalk-ca.pem >> "$out"
