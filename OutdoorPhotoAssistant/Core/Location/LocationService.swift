import Combine
import CoreLocation
import Foundation

/// 定位 + 太阳时（NOAA 近似）。算法经审查是正确的，这里只修了授权流程的幂等性。
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()

    @Published var authorizationDenied = false
    @Published var sunrise: Date?
    @Published var sunset: Date?
    @Published var periodText = ""
    @Published var locationText = ""

    private var started = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func start() {
        guard CLLocationManager.locationServicesEnabled() else {
            updatePeriod(sunrise: sunrise, sunset: sunset)
            return
        }
        if !started {
            started = true
            if manager.authorizationStatus == .notDetermined {
                manager.requestWhenInUseAuthorization()
            } else if manager.authorizationStatus == .authorizedAlways
                        || manager.authorizationStatus == .authorizedWhenInUse {
                manager.startUpdatingLocation()
            }
        }
        updatePeriod(sunrise: sunrise, sunset: sunset)
    }

    func stop() {
        started = false
        manager.stopUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        let denied = status == .denied || status == .restricted
        DispatchQueue.main.async { self.authorizationDenied = denied }
        if started && (status == .authorizedAlways || status == .authorizedWhenInUse) {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let coordinate = location.coordinate
        let times = SolarCalculator.sunTimes(date: Date(),
                                             latitude: coordinate.latitude,
                                             longitude: coordinate.longitude)
        let text = String(format: "%.4f, %.4f", coordinate.latitude, coordinate.longitude)
        DispatchQueue.main.async {
            self.locationText = text
            self.sunrise = times.sunrise
            self.sunset = times.sunset
            self.updatePeriod(now: Date(), sunrise: times.sunrise, sunset: times.sunset)
        }
    }

    private func updatePeriod(now: Date = Date(), sunrise: Date? = nil, sunset: Date? = nil) {
        if let sunrise, let sunset {
            let calendar = Calendar.current
            guard let blueBefore = calendar.date(byAdding: .minute, value: -30, to: sunrise),
                  let goldenStart = calendar.date(byAdding: .minute, value: -60, to: sunset),
                  let blueAfter = calendar.date(byAdding: .minute, value: 30, to: sunset) else {
                periodText = "日间"
                return
            }
            if now < blueBefore {
                periodText = "夜景"
            } else if now < sunrise {
                periodText = "蓝调时刻"
            } else if now < goldenStart {
                periodText = "日间"
            } else if now < sunset {
                periodText = "黄金时段"
            } else if now < blueAfter {
                periodText = "蓝调时刻"
            } else {
                periodText = "夜景"
            }
            return
        }

        let hour = Calendar.current.component(.hour, from: now)
        if hour < 6 {
            periodText = "蓝调时刻"
        } else if hour < 10 {
            periodText = "日间"
        } else if hour < 16 {
            periodText = "日间"
        } else if hour < 19 {
            periodText = "黄金时段"
        } else if hour < 21 {
            periodText = "蓝调时刻"
        } else {
            periodText = "夜景"
        }
    }
}

private enum SolarCalculator {
    struct Times {
        let sunrise: Date?
        let sunset: Date?
    }

    static func sunTimes(date: Date, latitude: Double, longitude: Double) -> Times {
        let calendar = Calendar(identifier: .gregorian)
        var components = calendar.dateComponents(in: TimeZone.current, from: date)
        components.hour = 12
        components.minute = 0
        components.second = 0
        guard let noon = calendar.date(from: components) else {
            return Times(sunrise: nil, sunset: nil)
        }

        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: noon) ?? 1
        let gamma = 2.0 * Double.pi / 365.0 * Double(dayOfYear - 1)
        let declination = 0.006918
            - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        let equationOfTime = 229.18 * (0.000075
            + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))

        let latitudeRad = latitude * Double.pi / 180
        let zenith = 90.833 * Double.pi / 180
        let cosHourAngle = (cos(zenith) - sin(latitudeRad) * sin(declination)) / (cos(latitudeRad) * cos(declination))
        guard cosHourAngle >= -1, cosHourAngle <= 1 else {
            return Times(sunrise: nil, sunset: nil)
        }

        let hourAngle = acos(cosHourAngle) * 180 / Double.pi
        let timeZoneHours = Double(TimeZone.current.secondsFromGMT(for: noon)) / 3600
        let solarNoonMinutes = 720 - 4 * longitude - equationOfTime + timeZoneHours * 60

        return Times(sunrise: dateAtMinutes(solarNoonMinutes - hourAngle * 4, from: noon, calendar: calendar),
                     sunset: dateAtMinutes(solarNoonMinutes + hourAngle * 4, from: noon, calendar: calendar))
    }

    private static func dateAtMinutes(_ minutes: Double, from noon: Date, calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: noon)
        return start.addingTimeInterval(minutes * 60)
    }
}
