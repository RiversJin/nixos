{
  # Reserved for routed Claude namespaces; never NAT these on the client host.
  # The proxy generator uses the same prefix in src/config/claude-network.js.
  cidr = "10.203.0.0/24";
  router = "192.168.50.1";
  adapterPort = 7893;
  peers = {
    rivers-gateway = {
      lanAddress = "192.168.50.2";
      subnet = "10.203.0.0/30";
      hostAddress = "10.203.0.1";
      namespaceAddress = "10.203.0.2";
    };
    rivers-host = {
      lanAddress = "192.168.50.10";
      subnet = "10.203.0.4/30";
      hostAddress = "10.203.0.5";
      namespaceAddress = "10.203.0.6";
    };
    rivers-laptop = {
      lanAddress = "192.168.50.11";
      subnet = "10.203.0.8/30";
      hostAddress = "10.203.0.9";
      namespaceAddress = "10.203.0.10";
    };
  };
}
