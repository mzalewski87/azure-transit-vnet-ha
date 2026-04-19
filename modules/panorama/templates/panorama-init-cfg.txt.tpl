type=dhcp-client
hostname=${hostname}
%{ if serial_number != "" ~}
serial=${serial_number}
%{ endif ~}
authcodes=${panorama_auth_code}
dns-primary=168.63.129.16
dns-secondary=8.8.8.8
ntp-server-1=0.europe.pool.ntp.org
ntp-server-2=1.europe.pool.ntp.org
timezone=Europe/Warsaw
dhcp-send-hostname=yes
dhcp-send-client-id=yes
dhcp-accept-server-hostname=yes
dhcp-accept-server-domain=yes
