{ ... }: {
  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  age.secrets = {
    controller-header = {
      file = ../../secrets/rivers-gateway-controller-header.age;
      path = "/run/router-secrets/controller-header";
      symlink = false;
    };
    pppoe-options = {
      file = ../../secrets/rivers-gateway-pppoe-options.age;
      path = "/run/router-secrets/pppoe-options";
      symlink = false;
    };
    pppoe-secrets = {
      file = ../../secrets/rivers-gateway-pppoe-secrets.age;
      path = "/run/router-secrets/pppoe-secrets";
      symlink = false;
    };
    router-password = {
      file = ../../secrets/rivers-gateway-router-password.age;
      path = "/run/router-secrets/password-hash";
      symlink = false;
    };
    aria2-rpc = {
      file = ../../secrets/rivers-gateway-aria2-rpc.age;
    };
    wg-private-key = {
      file = ../../secrets/rivers-gateway-wg-private-key.age;
    };
    wg-preshared-key = {
      file = ../../secrets/rivers-gateway-wg-preshared-key.age;
    };
    proxy-generator-env = {
      file = ../../secrets/rivers-gateway-proxy-generator-env.age;
      owner = "rivers";
    };
    webdav-htpasswd = {
      file = ../../secrets/rivers-gateway-webdav-htpasswd.age;
      owner = "rivers";
    };
  };
}
