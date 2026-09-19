let
  admin = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB88UzWy7D87cgUAvO+I/KcwrYM7XIFgBkLiOn4a6qq6";
  rivers-host = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJt2uPcaPbP4bALyYL5rhFRJSGnR6di+fOmI7Eo/Rtnu";
  rivers-laptop = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJbb1UIPfXhR2jjbCa62WPwmEDJnWI63ARP8GPmQQmmd";
  rivers-gateway = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMkMyBntF7Ncy7UVtGCBwQIwFNnEtWqWjfkiGaCRrmUy";
in
{
  "rivers-host-mimo-token.age".publicKeys = [ admin rivers-host ];
  "rivers-host-mihomo-subscription.age".publicKeys = [ admin rivers-host ];
  "rivers-host-mihomo-controller.age".publicKeys = [ admin rivers-host ];
  "rivers-laptop-mihomo-subscription.age".publicKeys = [ admin rivers-laptop ];
  "rivers-laptop-mihomo-controller.age".publicKeys = [ admin rivers-laptop ];
  "rivers-laptop-sing-box-subscription.age".publicKeys = [ admin rivers-laptop ];
  "rivers-laptop-sing-box-controller.age".publicKeys = [ admin rivers-laptop ];
  "rivers-gateway-pppoe-options.age".publicKeys = [ admin rivers-gateway ];
  "rivers-gateway-pppoe-secrets.age".publicKeys = [ admin rivers-gateway ];
  "rivers-gateway-router-password.age".publicKeys = [ admin rivers-gateway ];
  "rivers-gateway-aria2-rpc.age".publicKeys = [ admin rivers-gateway ];
  "rivers-gateway-wg-private-key.age".publicKeys = [ admin rivers-gateway ];
  "rivers-gateway-wg-preshared-key.age".publicKeys = [ admin rivers-gateway ];
  "rivers-gateway-proxy-generator-env.age".publicKeys = [ admin rivers-gateway ];
  "rivers-gateway-webdav-htpasswd.age".publicKeys = [ admin rivers-gateway ];
  "rivers-gateway-controller-header.age".publicKeys = [ admin rivers-gateway ];
}
