# /etc/profile.d/99-ps1.sh
# A friendly prompt for interactive shells inside the container.
if [ -n "$PS1" ]; then
  export PS1="[\[\e[32m\]\u\[\e[0m\]@\[\e[34m\]\h\[\e[0m\] \[\e[33m\]\W\[\e[0m\]]$ "
fi
