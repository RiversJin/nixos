{ ... }: {
  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  age.secrets = {
    mimo-token = {
      file = ../../secrets/rivers-host-mimo-token.age;
      owner = "rivers";
    };
    mihomo-subscription = {
      file = ../../secrets/rivers-host-mihomo-subscription.age;
    };
    mihomo-controller = {
      file = ../../secrets/rivers-host-mihomo-controller.age;
    };
  };
}
