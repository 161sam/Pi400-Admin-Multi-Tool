use iced::widget::{button, column, container, row, scrollable, text, Space};
use iced::{Alignment, Application, Command, Element, Settings, Theme};
use serde::Serialize;

const API: &str = "http://127.0.0.1:5000";
const SERVICES: &[&str] = &[
    "target-ssh",
    "target-serial",
    "pi400-hid",
];

#[derive(Default)]
struct App {
    status: String,
    busy: bool,
    last_error: Option<String>,
}

#[derive(Debug, Clone)]
enum Action { Start, Stop, Restart }

#[derive(Debug, Clone)]
enum Msg {
    Refresh,
    StatusLoaded(String),
    LogsLoaded(String),
    SvcAction(Action, &'static str),
    ActionDone(Result<String, String>),
}

#[derive(Serialize)]
struct SvcReq<'a> { name: &'a str }

impl Application for App {
    type Executor = iced::executor::Default;
    type Message = Msg;
    type Theme = Theme;
    type Flags = ();

    fn new(_flags: Self::Flags) -> (Self, Command<Msg>) {
        (
            Self { status: String::new(), busy: false, last_error: None },
            Command::batch(vec![load_status(), load_logs()]),
        )
    }

    fn title(&self) -> String { "Pi400 Admin Panel".into() }

    fn update(&mut self, message: Msg) -> Command<Msg> {
        match message {
            Msg::Refresh => {
                self.busy = true;
                return Command::batch(vec![load_status(), load_logs()]);
            }
            Msg::StatusLoaded(s) => { self.busy = false; self.status = s; }
            Msg::LogsLoaded(s) => { self.busy = false; if !self.status.is_empty() { self.status.push_str("\n\n"); } self.status.push_str(&s); }
            Msg::SvcAction(action, svc) => { self.busy = true; return svc_command(action, svc); }
            Msg::ActionDone(res) => {
                self.busy = false;
                match res {
                    Ok(txt) => { self.last_error = None; if !txt.trim().is_empty() { if !self.status.is_empty() { self.status.push_str("\n\n"); } self.status.push_str(&txt); } return load_status(); }
                    Err(e) => { self.last_error = Some(e); }
                }
            }
        }
        Command::none()
    }

    fn view(&self) -> Element<Msg> {
        let mut svc_buttons = row![]
            .spacing(8)
            .align_items(Alignment::Center);

        for &svc in SERVICES {
            svc_buttons = svc_buttons
                .push(button(text(format!("▶ {}", svc))).on_press(Msg::SvcAction(Action::Start, svc)))
                .push(button(text("⟳").size(20)).on_press(Msg::SvcAction(Action::Restart, svc)))
                .push(button(text("■")).on_press(Msg::SvcAction(Action::Stop, svc)))
                .push(Space::with_width(8));
        }

        let top_bar = row![
            button(text("⟲ Aktualisieren")).on_press(Msg::Refresh),
            Space::with_width(16),
            if let Some(err) = &self.last_error { text(format!("Fehler: {}", err)) } else { text("") },
        ]
        .spacing(10)
        .align_items(Alignment::Center);

        let content = column![
            top_bar,
            svc_buttons,
            scrollable(container(text(self.status.clone()).size(16)).padding(12)).height(iced::Length::Fill),
        ]
        .spacing(12)
        .padding(12);

        container(content)
            .width(iced::Length::Fill)
            .height(iced::Length::Fill)
            .center_x()
            .center_y()
            .into()
    }

    fn theme(&self) -> Theme { Theme::Dark }

    fn run(settings: Settings<()>) -> iced::Result {
        let mut settings = settings;
        settings.window.size = (800, 480);
        settings.window.decorations = false;
        settings.window.maximized = true;
        Self::run(settings)
    }
}

fn load_status() -> Command<Msg> {
    Command::perform(async move {
        match ureq::get(&format!("{}/api/status/services", API)).call() { Ok(resp) => resp.into_string().map_err(|e| e.to_string()), Err(e) => Err(e.to_string()), }
    }, |res| match res { Ok(body) => Msg::StatusLoaded(parse_text(&body)), Err(e) => Msg::ActionDone(Err(e)), })
}

fn load_logs() -> Command<Msg> {
    Command::perform(async move {
        match ureq::get(&format!("{}/api/logs", API)).call() { Ok(resp) => resp.into_string().map_err(|e| e.to_string()), Err(e) => Err(e.to_string()), }
    }, |res| match res { Ok(body) => Msg::LogsLoaded(parse_text(&body)), Err(e) => Msg::ActionDone(Err(e)), })
}

fn svc_command(action: Action, svc: &'static str) -> Command<Msg> {
    Command::perform(async move {
        let body = serde_json::to_string(&SvcReq { name: svc }).unwrap();
        let endpoint = match action { Action::Start => "start", Action::Stop => "stop", Action::Restart => "restart" };
        let req = ureq::post(&format!("{}/api/svc/{}", API, endpoint))
            .set("Content-Type", "application/json")
            .send_string(&body);
        match req { Ok(resp) => resp.into_string().map_err(|e| e.to_string()), Err(e) => Err(e.to_string()), }
    }, |res| match res { Ok(body) => Msg::ActionDone(Ok(parse_text(&body))), Err(e) => Msg::ActionDone(Err(e)), })
}

fn parse_text(body: &str) -> String {
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(body) {
        if v.get("ok").and_then(|b| b.as_bool()) == Some(true) {
            if let Some(t) = v.get("data").and_then(|d| d.get("text")).and_then(|t| t.as_str()) { return t.to_string(); }
        }
        if let Some(e) = v.get("error").and_then(|t| t.as_str()) { return format!("error: {}", e); }
    }
    body.to_string()
}
