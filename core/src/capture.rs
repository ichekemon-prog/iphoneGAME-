//! Engine: reads WDA's MJPEG stream on the iPhone itself (127.0.0.1:9100).
//! Game independent.
use std::time::Duration;

use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};

use crate::wda::{MJPEG_PORT, find};

const MAX_BUFFER: usize = 16 * 1024 * 1024;

pub struct Mjpeg {
    stream: TcpStream,
    buf: Vec<u8>,
    started: bool,
}

impl Mjpeg {
    pub async fn connect() -> Result<Mjpeg, String> {
        let mut stream = tokio::time::timeout(Duration::from_secs(5), TcpStream::connect(("127.0.0.1", MJPEG_PORT)))
            .await
            .map_err(|_| "MJPEG: 接続タイムアウト".to_string())?
            .map_err(|e| format!("MJPEG: 接続失敗 io={:?}", e.kind()))?;
        stream
            .write_all(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
            .await
            .map_err(|e| format!("MJPEG: 送信失敗 io={:?}", e.kind()))?;
        Ok(Mjpeg { stream, buf: Vec::with_capacity(1 << 20), started: false })
    }

    async fn fill(&mut self) -> Result<(), String> {
        let mut tmp = vec![0u8; 65536];
        let n = self.stream.read(&mut tmp).await.map_err(|e| format!("MJPEG: 受信失敗 io={:?}", e.kind()))?;
        if n == 0 {
            return Err("MJPEG: 接続が閉じられました".into());
        }
        self.buf.extend_from_slice(&tmp[..n]);
        if self.buf.len() > MAX_BUFFER {
            return Err("MJPEG: 想定外に大きいデータ".into());
        }
        Ok(())
    }

    /// Next JPEG frame. Uses the part's Content-Length when present and
    /// falls back to JPEG start/end markers.
    pub async fn next_frame(&mut self) -> Result<Vec<u8>, String> {
        if !self.started {
            loop {
                if let Some(h) = find(&self.buf, b"\r\n\r\n") {
                    let head = String::from_utf8_lossy(&self.buf[..h]).to_string();
                    if !head.split_whitespace().nth(1).is_some_and(|c| c == "200") {
                        return Err("MJPEG: HTTP 200以外の応答".into());
                    }
                    self.buf.drain(..h + 4);
                    self.started = true;
                    break;
                }
                self.fill().await?;
            }
        }
        loop {
            if let Some(soi) = find(&self.buf, &[0xFF, 0xD8]) {
                let head = String::from_utf8_lossy(&self.buf[..soi]).to_ascii_lowercase();
                let len = head
                    .rfind("content-length:")
                    .and_then(|i| head[i + 15..].lines().next())
                    .and_then(|v| v.trim().parse::<usize>().ok());
                if let Some(len) = len {
                    while self.buf.len() < soi + len {
                        self.fill().await?;
                    }
                    let frame = self.buf[soi..soi + len].to_vec();
                    self.buf.drain(..soi + len);
                    return Ok(frame);
                }
                if let Some(e) = find(&self.buf[soi + 2..], &[0xFF, 0xD9]) {
                    let end = soi + 2 + e + 2;
                    let frame = self.buf[soi..end].to_vec();
                    self.buf.drain(..end);
                    return Ok(frame);
                }
            }
            self.fill().await?;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::TcpListener;

    #[tokio::test]
    async fn reads_frames_with_and_without_length() {
        let listener = TcpListener::bind(("127.0.0.1", MJPEG_PORT)).await.unwrap();
        tokio::spawn(async move {
            let (mut s, _) = listener.accept().await.unwrap();
            let mut req = [0u8; 256];
            let _ = s.read(&mut req).await;
            let f1 = [0xFF, 0xD8, 1, 2, 0xFF, 0xD9, 3, 0xFF, 0xD9]; // EOI inside: needs Content-Length
            let f2 = [0xFF, 0xD8, 9, 9, 0xFF, 0xD9];
            let mut out = b"HTTP/1.0 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=--BoundaryString\r\n\r\n".to_vec();
            out.extend(format!("--BoundaryString\r\nContent-type: image/jpg\r\nContent-Length: {}\r\n\r\n", f1.len()).as_bytes());
            out.extend(f1);
            out.extend(b"\r\n\r\n--BoundaryString\r\nContent-type: image/jpg\r\n\r\n");
            out.extend(f2);
            for chunk in out.chunks(5) {
                s.write_all(chunk).await.unwrap();
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        });
        let mut m = Mjpeg::connect().await.unwrap();
        assert_eq!(m.next_frame().await.unwrap().len(), 9);
        assert_eq!(m.next_frame().await.unwrap(), vec![0xFF, 0xD8, 9, 9, 0xFF, 0xD9]);
    }
}
