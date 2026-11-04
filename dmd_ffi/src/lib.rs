//! A small C ABI over `dmd_core::dmd::Dmd`.
//!
//! dmd_core's own exported functions use the Rust ABI and one global instance; this
//! wrapper gives each terminal its own handle and real `extern "C"` entry points.
//! Every call takes the handle's lock, so the emulation thread and the UI thread can
//! both call in.

use dmd_core::dmd::Dmd;
use std::os::raw::c_int;
use std::sync::Mutex;

pub struct AttDmd {
    dmd: Mutex<Dmd>,
}

pub const ATT_DMD_VIDEO_BYTES: usize = 100 * 1024; // 800 x 1024, 1 bit per pixel, MSB first
pub const ATT_DMD_NVRAM_BYTES: usize = 8192;

fn with<R>(h: *mut AttDmd, f: impl FnOnce(&mut Dmd) -> R) -> Option<R> {
    if h.is_null() {
        return None;
    }
    let handle = unsafe { &*h };
    let mut dmd = handle.dmd.lock().ok()?;
    Some(f(&mut dmd))
}

/// Create and reset a terminal. Returns NULL on failure.
#[no_mangle]
pub extern "C" fn att_dmd_create() -> *mut AttDmd {
    let mut dmd = Dmd::new();
    if dmd.reset().is_err() {
        return std::ptr::null_mut();
    }
    Box::into_raw(Box::new(AttDmd { dmd: Mutex::new(dmd) }))
}

#[no_mangle]
pub extern "C" fn att_dmd_destroy(h: *mut AttDmd) {
    if !h.is_null() {
        unsafe { drop(Box::from_raw(h)) };
    }
}

/// Reset the CPU and reload the ROM (like power-cycling the terminal). 0 on success.
#[no_mangle]
pub extern "C" fn att_dmd_reset(h: *mut AttDmd) -> c_int {
    match with(h, |d| d.reset()) {
        Some(Ok(())) => 0,
        _ => 1,
    }
}

/// Execute `steps` CPU instructions.
#[no_mangle]
pub extern "C" fn att_dmd_run(h: *mut AttDmd, steps: u32) {
    with(h, |d| d.run(steps as usize));
}

/// Copy video RAM (100 bytes per row, 1024 rows) into `out` and return the DUART
/// output port; bit 0x02 set means dark-on-light.
#[no_mangle]
pub extern "C" fn att_dmd_copy_video(h: *mut AttDmd, out: *mut u8, len: usize) -> u8 {
    with(h, |d| {
        let vram = d.video_ram();
        let n = len.min(vram.len());
        if !out.is_null() {
            unsafe { std::ptr::copy_nonoverlapping(vram.as_ptr(), out, n) };
        }
        d.duart_output()
    })
    .unwrap_or(0)
}

/// A byte arriving from the host on the RS-232 line.
#[no_mangle]
pub extern "C" fn att_dmd_rx_char(h: *mut AttDmd, c: u8) {
    with(h, |d| d.rx_char(c));
}

/// A key code from the keyboard.
#[no_mangle]
pub extern "C" fn att_dmd_rx_keyboard(h: *mut AttDmd, c: u8) {
    with(h, |d| d.rx_keyboard(c));
}

/// Mouse position in terminal coordinates: x 0..799, y 0..1023 with 0 at the bottom.
#[no_mangle]
pub extern "C" fn att_dmd_mouse_move(h: *mut AttDmd, x: u16, y: u16) {
    with(h, |d| d.mouse_move(x, y));
}

/// Buttons are 0 (left), 1 (middle), 2 (right).
#[no_mangle]
pub extern "C" fn att_dmd_mouse_down(h: *mut AttDmd, button: u8) {
    with(h, |d| d.mouse_down(button));
}

#[no_mangle]
pub extern "C" fn att_dmd_mouse_up(h: *mut AttDmd, button: u8) {
    with(h, |d| d.mouse_up(button));
}

/// Drain bytes the terminal sent to the host. Returns how many were written to `out`.
#[no_mangle]
pub extern "C" fn att_dmd_rs232_tx(h: *mut AttDmd, out: *mut u8, max: usize) -> usize {
    with(h, |d| {
        let mut n = 0;
        while n < max {
            match d.rs232_tx_poll() {
                Some(c) => {
                    unsafe { *out.add(n) = c };
                    n += 1;
                }
                None => break,
            }
        }
        n
    })
    .unwrap_or(0)
}

/// Next byte the terminal sent to its keyboard (bit 0x08 = ring the bell), or -1.
#[no_mangle]
pub extern "C" fn att_dmd_kb_tx(h: *mut AttDmd) -> c_int {
    with(h, |d| d.kb_tx_poll().map(c_int::from).unwrap_or(-1)).unwrap_or(-1)
}

/// Load 8 KB of setup NVRAM (baud rate, options, etc.).
#[no_mangle]
pub extern "C" fn att_dmd_set_nvram(h: *mut AttDmd, data: *const u8) {
    if data.is_null() {
        return;
    }
    let buf = unsafe { std::slice::from_raw_parts(data, ATT_DMD_NVRAM_BYTES) };
    with(h, |d| d.set_nvram(buf));
}

#[no_mangle]
pub extern "C" fn att_dmd_get_nvram(h: *mut AttDmd, out: *mut u8) {
    if out.is_null() {
        return;
    }
    with(h, |d| {
        let nv = d.get_nvram();
        let n = nv.len().min(ATT_DMD_NVRAM_BYTES);
        unsafe { std::ptr::copy_nonoverlapping(nv.as_ptr(), out, n) };
    });
}
