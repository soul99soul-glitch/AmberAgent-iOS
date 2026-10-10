use std::{fs::OpenOptions, io::Write, os::unix::fs::OpenOptionsExt, time::Duration};
use idevice::{
    IdeviceService, RemoteXpcClient,
    core_device_proxy::CoreDeviceProxy,
    remote_pairing::{RemotePairingClient, RpPairingFile},
    rsd::RsdHandshake,
    usbmuxd::{UsbmuxdAddr, UsbmuxdConnection},
};

// One-time provisioning only. Never launch or maintain XCTest from this computer.
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 { return Err("usage: amber-phone-prepare <device UDID> <new output plist>".into()); }
    // Reserve a private new file before changing device pairing state. Never overwrite a record.
    let mut output = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&args[2])?;
    let pairing = tokio::time::timeout(Duration::from_secs(60), async {
        let mut mux = UsbmuxdConnection::default().await?;
        let device = mux.get_device(&args[1]).await?;
        let provider = device.to_provider(UsbmuxdAddr::from_env_var()?, "AmberSelfControlPrepare");
        let proxy = CoreDeviceProxy::connect(&provider).await?;
        let port = proxy.tunnel_info().server_rsd_port;
        let mut adapter = proxy.create_software_tunnel()?.to_async_handle();
        let rsd = RsdHandshake::new(adapter.connect(port).await?).await?;
        let service = rsd.services.get("com.apple.internal.dt.coredevice.untrusted.tunnelservice")
            .ok_or("device does not expose the untrusted pairing service")?;
        let mut xpc = RemoteXpcClient::new(adapter.connect(service.port).await?).await?;
        xpc.do_handshake().await?;
        let _ = xpc.recv_root().await?;
        let hostname = "AmberSelfControl";
        let mut file = RpPairingFile::generate(hostname);
        let mut client = RemotePairingClient::new(xpc, hostname);
        client.connect(&mut file, async || "000000".to_owned()).await?;
        Ok::<_, Box<dyn std::error::Error>>(file.to_bytes())
    }).await??;
    output.write_all(&pairing)?;
    output.sync_all()?;
    println!("Created a private RemotePairing record. No key material was logged. No XCTest session was started.");
    Ok(())
}
