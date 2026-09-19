{ ... }: {
  age.identityPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  age.secrets = {
    mihomo-subscription = {
      file = ../../secrets/rivers-laptop-mihomo-subscription.age;
    };
    mihomo-controller = {
      file = ../../secrets/rivers-laptop-mihomo-controller.age;
    };
    sing-box-subscription = {
      file = ../../secrets/rivers-laptop-sing-box-subscription.age;
    };
    sing-box-controller = {
      file = ../../secrets/rivers-laptop-sing-box-controller.age;
    };
  };
}
