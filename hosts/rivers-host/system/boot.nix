{ lib, pkgs, ... }:

let
  # LLD 23 includes the symbol-initialization fix needed with GCC 16 builds.
  llvm = pkgs.llvmPackages_23;
  kernelStdenv = pkgs.overrideCC pkgs.stdenv (llvm.clang.override { bintools = llvm.bintools; });
  kernelBindgen = pkgs.rust-bindgen-unwrapped.override { clang = llvm.clang; };
in
{
  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.consoleMode = "max";
  boot.loader.timeout = 5;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.kernelPackages = pkgs.linuxPackages_latest.extend (
    _: prev: {
      kernel =
        (prev.kernel.override (args: {
          stdenv = kernelStdenv;
          # libclang must understand the same C flags/extensions as the compiler.
          extraMakeFlags = (args.extraMakeFlags or [ ]) ++ [ "BINDGEN=${lib.getExe kernelBindgen}" ];
        })).overrideAttrs
          (old: {
            # Native CPU code must be built here, rather than fetched from a cache.
            preferLocalBuild = true;
            allowSubstitutes = false;
            postPatch = (old.postPatch or "") + ''
              if ! grep -q 'AMD Ryzen 7 5800X 8-Core Processor' /proc/cpuinfo; then
                echo "This native kernel must be built on the rivers-host Ryzen 7 5800X." >&2
                exit 1
              fi
            '';
          });
    }
  );
  # Allow PCIe P2P routing globally. ACS redirection through the CPU root port
  # breaks peer reads on this host; pci:0:0 matches every PCI device.
  # Configure this during PCI initialization so resume restores the same policy.
  boot.kernelParams = [ "pci=disable_acs_redir=pci:0:0" ];
  boot.kernelPatches = [
    {
      # Same GPU ID does not imply the same board VBIOS on this dual-XTX host.
      name = "amdgpu-vfct-exact-pci-match";
      patch = ../patches/amdgpu-vfct-exact-pci-match.patch;
    }
    {
      # Trim alternate GPU and enterprise storage drivers on this AMD desktop.
      # Keep all media/capture, networking/RDMA, USB, audio, AMD KFD, and
      # host/guest virtualization support.
      name = "rivers-host-kernel-tuning";
      patch = null;
      structuredExtraConfig = {
        # Ryzen 7 5800X has 16 logical CPUs; leave room for a 32-thread CPU.
        NR_CPUS = lib.mkForce (lib.kernel.freeform "32");
        X86_NATIVE_CPU = lib.mkForce lib.kernel.yes;
        LTO_NONE = lib.mkForce lib.kernel.yes;
        LTO_CLANG_THIN = lib.mkForce lib.kernel.no;
      }
      // lib.genAttrs [
        "DRM_I915"
        "DRM_XE"
        "DRM_NOUVEAU"
        "DRM_RADEON"

        "MEGARAID_NEWGEN"
        "MEGARAID_SAS"
        "SCSI_MPT2SAS"
        "SCSI_MPT3SAS"
        "SCSI_HPSA"
        "SCSI_SMARTPQI"
        "SCSI_QLA_FC"
        "SCSI_LPFC"
      ] (_: lib.mkForce lib.kernel.no)
      # These common-config requests depend on drivers disabled above.
      // lib.genAttrs [
        "DRM_NOUVEAU_SVM"
        "DRM_I915_GVT"
        "DRM_I915_GVT_KVMGT"
      ] (_: lib.mkForce lib.kernel.unset);
    }
  ];
  boot.kernelModules = [ "nct6683" ];
  hardware.enableAllFirmware = true;

  # AMD GPU
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };
}
