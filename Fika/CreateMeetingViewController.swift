import UIKit
import UserNotifications

class CreateMeetingViewController : UIViewController {

    var stream: Stream!

    @IBOutlet weak var datePicker: UIDatePicker!
    @IBOutlet weak var mondayButton: ToggleButton!
    @IBOutlet weak var tuesdayButton: ToggleButton!
    @IBOutlet weak var wednesdayButton: ToggleButton!
    @IBOutlet weak var thursdayButton: ToggleButton!
    @IBOutlet weak var fridayButton: ToggleButton!
    @IBOutlet weak var saturdayButton: ToggleButton!
    @IBOutlet weak var sundayButton: ToggleButton!

    override func viewDidLoad() {
        guard
            let meetingTimes = self.stream.meetingTimes,
            let hour = meetingTimes.first?.hour,
            let minute = meetingTimes.first?.minute,
            let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) else {
                if let date = Calendar.current.date(bySettingHour: 8, minute: 30, second: 0, of: Date()) {
                    self.datePicker.setDate(date, animated: false)
                }
                return
        }

        // Set the date picker to reflect the time of the first meeting
        self.datePicker.setDate(date, animated: false)
        // Highlight the respective day of each meeting time
        meetingTimes.forEach { component in
            guard let day = component.weekday else {
                return
            }
            switch day {
            case 1:
                self.sundayButton.isOn = true
            case 2:
                self.mondayButton.isOn = true
            case 3:
                self.tuesdayButton.isOn = true
            case 4:
                self.wednesdayButton.isOn = true
            case 5:
                self.thursdayButton.isOn = true
            case 6:
                self.fridayButton.isOn = true
            case 7:
                self.saturdayButton.isOn = true
            default:
                break
            }
        }
    }

    @IBAction func closeTapped(_ sender: Any) {
        self.dismiss(animated: true, completion: nil)
    }

    @IBAction func confirmTapped(_ sender: Any) {
        let utcComponents = Calendar.current.dateComponents(
            in: TimeZone(abbreviation: "UTC")!, from: self.datePicker.date)
        let hour = utcComponents.hour
        let minute = utcComponents.minute

        // TODO: Make this a component which returns which days are selected
        var meetingTimes = [DateComponents]()
        if self.sundayButton.isOn {
            meetingTimes.append(DateComponents(hour: hour, minute: minute, weekday: 1))
        }
        if self.mondayButton.isOn {
            meetingTimes.append(DateComponents(hour: hour, minute: minute, weekday: 2))
        }
        if self.tuesdayButton.isOn {
            meetingTimes.append(DateComponents(hour: hour, minute: minute, weekday: 3))
        }
        if self.wednesdayButton.isOn {
            meetingTimes.append(DateComponents(hour: hour, minute: minute, weekday: 4))
        }
        if self.thursdayButton.isOn {
            meetingTimes.append(DateComponents(hour: hour, minute: minute, weekday: 5))
        }
        if self.fridayButton.isOn {
            meetingTimes.append(DateComponents(hour: hour, minute: minute, weekday: 6))
        }
        if self.saturdayButton.isOn {
            meetingTimes.append(DateComponents(hour: hour, minute: minute, weekday: 7))
        }

        DispatchQueue.global().async {
            self.stream.meetingTimes = meetingTimes.isEmpty ? nil : meetingTimes
        }

        self.dismiss(animated: true, completion: nil)
    }
}

class ToggleButton: HighlightButton {

    var isOn: Bool = false {
        didSet {
            if self.isOn {
                self.backgroundColor = .black
                self.layer.borderWidth = 0
            } else {
                self.backgroundColor = .clear
                self.borderColor = .lightGray
                self.layer.borderWidth = 1
            }
            self.setTitleColor(self.isOn ? .white : .black, for: .normal)
        }
    }

    override func awakeFromNib() {
        super.awakeFromNib()
        self.isOn = false
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        self.isOn = !self.isOn
    }
}
