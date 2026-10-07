//! Normalized full-image coordinates to current WDA viewport points.
pub fn point(x: f64, y: f64, size: (f64, f64)) -> Result<(f64, f64), String> {
    if !x.is_finite() || !y.is_finite() || !(0.0..=1000.0).contains(&x) || !(0.0..=1000.0).contains(&y) {
        return Err("座標は0〜1000の有限数で指定してください".into());
    }
    if !size.0.is_finite() || !size.1.is_finite() || size.0 < 1.0 || size.1 < 1.0 {
        return Err("画面サイズが不正です".into());
    }
    Ok(((x / 1000.0 * size.0).round().min(size.0 - 1.0),
        (y / 1000.0 * size.1).round().min(size.1 - 1.0)))
}

pub fn check_image(width: f64, height: f64, size: (f64, f64)) -> Result<(), String> {
    if !width.is_finite() || !height.is_finite() || width <= 0.0 || height <= 0.0
        || !size.0.is_finite() || !size.1.is_finite() || size.0 < 1.0 || size.1 < 1.0 {
        return Err("画像または画面サイズが不正です".into());
    }
    if ((width / height) / (size.0 / size.1) - 1.0).abs() > 0.03 {
        return Err("判断画像と現在の画面の縦横比が違います。回転・画像範囲を確認してください".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn retina_and_half_size_use_the_same_normalized_position() {
        let viewport = (393.0, 852.0);
        assert!(check_image(1179.0, 2556.0, viewport).is_ok());
        assert!(check_image(590.0, 1278.0, viewport).is_ok());
        assert_eq!(point(430.0, 390.0, viewport).unwrap(), (169.0, 332.0));
        assert_eq!(point(1000.0, 1000.0, viewport).unwrap(), (392.0, 851.0));
    }
    #[test]
    fn rejects_invalid_coordinates_and_rotated_or_cropped_images() {
        assert!(point(-1.0, 100.0, (393.0, 852.0)).is_err());
        assert!(point(f64::NAN, 100.0, (393.0, 852.0)).is_err());
        assert!(point(1001.0, 100.0, (393.0, 852.0)).is_err());
        assert!(check_image(1179.0, 2556.0, (852.0, 393.0)).is_err());
        assert!(check_image(1179.0, 2000.0, (393.0, 852.0)).is_err());
    }
}
