# runtime-nano.sh - intentionally empty. Nothing sources this file.
#
# The Nano container runtime was removed from this kit (Exasol Personal is the
# only runtime). The file stays for ONE reason: `exakit update` in a kit 0.1.0
# install validates the downloaded kit against a fixed list of required files,
# and this name is on it (v0.1.0 setup/lib/common.sh). Without it every 0.1.0
# install's update refused 0.2.0 as "Downloaded starter kit is incomplete
# (missing setup/lib/runtime-nano.sh)". Keep it until no 0.1.0 installs remain;
# it defines nothing and changes nothing.
