type=dhcp-client
hostname=${hostname}
%{ if serial_number != "" ~}
serial=${serial_number}
%{ endif ~}
authcodes=${panorama_auth_code}
dns-primary=168.63.129.16
dhcp-send-hostname=yes
dhcp-send-client-id=yes
dhcp-accept-server-hostname=yes
dhcp-accept-server-domain=yes
