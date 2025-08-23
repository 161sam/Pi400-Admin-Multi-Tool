use iced::widget::{button, column, container, row, scrollable, text, toggler, pick_list, Space};
use iced::{Alignment, Application, Command, Element, Settings, Theme};
use serde::Serialize;

const API: &str = "http://127.0.0.1:5000";
const SERVICES: &[&str] = &["pi400-hid","target-ssh","target-serial-tcp","kiosk","admin-backend"]; // exposed in backend whitelist
const UPLINKS: &[&str] = &["eth0","wlan0"];

#[derive(Default)]
struct App {
    page: Page,
    status: String,
    busy: bool,
    last_error: Option<String>,
    nat_enabled: bool,
    uplink: &'static str,
    target_ip: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Page { Services, Network, Tools, Vault }
impl Default for Page { fn default() -> Self { Page::Services } }

#[derive(Debug, Clone)]
enum Action { Start, Stop, Restart }

#[derive(Debug, Clone)]
enum Msg {
    Go(Page),
    Refresh,
    StatusLoaded(String),
    LogsLoaded(String),
    SvcAction(Action, &'static str),
    NatToggle(bool),
    NatDone(Result<String,String>),
    UplinkPick(&'static str),
    TargetFound(String),
    UsbEnsure,
    Done(Result<String,String>),
}

#[derive(Serialize)]
struct SvcReq<'a> { name: &'a str }

#[derive(Serialize)]
struct NatReq<'a> { uplink: Option<&'a str> }

impl Application for App {
    type Executor = iced::executor::Default;
    type Message = Msg;
    type Theme = Theme;
    type Flags = ();

    fn new(_flags: Self::Flags) -> (Self, Command<Msg>) {
        (
            Self { uplink: "eth0", ..Default::default() },
            Command::batch(vec![load_status(), load_logs(), find_target_ip()]),
        )
    }

    fn title(&self) -> String { "Pi400 Admin Panel".into() }

    fn update(&mut self, message: Msg) -> Command<Msg> {
        match message {
            Msg::Go(p) => { self.page = p; }
            Msg::Refresh => { self.busy = true; return Command::batch(vec![load_status(), load_logs(), find_target_ip()]); }
            Msg::StatusLoaded(s) => { self.busy = false; self.status = s; }
            Msg::LogsLoaded(s) => { self.busy = false; if !self.status.is_empty() { self.status.push_str("\n\n"); } self.status.push_str(&s); }
            Msg::SvcAction(action, svc) => { self.busy = true; return svc_command(action, svc); }
            Msg::NatToggle(on) => { self.nat_enabled = on; self.busy = true; return nat_toggle(on, self.uplink); }
            Msg::NatDone(res) => { self.busy = false; if let Err(e)=res { self.last_error = Some(e); } else { self.last_error=None; } }
            Msg::UplinkPick(iface) => { self.uplink = iface; }
            Msg::TargetFound(ip) => { self.target_ip = ip.trim().to_string(); }
            Msg::UsbEnsure => { self.busy = true; return usb_ensure(); }
            Msg::Done(res) => { self.busy = false; match res { Ok(t)=>{ if !t.trim().is_empty(){ if !self.status.is_empty(){ self.status.push_str("\n\n"); } self.status.push_str(&t);}}, Err(e)=>{ self.last_error=Some(e);} } }
        }
        Command::none()
    }

    fn view(&self) -> Element<Msg> {
        // Nav bar
        let nav = row![
            button(text("Services")).on_press(Msg::Go(Page::Services)),
            button(text("Network")).on_press(Msg::Go(Page::Network)),
            button(text("Tools")).on_press(Msg::Go(Page::Tools)),
            button(text("Vault")).on_press(Msg::Go(Page::Vault)),
            Space::with_width(16),
            button(text("⟲ Refresh")).on_press(Msg::Refresh),
            Space::with_width(16),
            if let Some(err) = &self.last_error { text(format!("⚠ {}", err)) } else { text("") },
        ].spacing(10).align_items(Alignment::Center);

        let body: Element<_> = match self.page {
            Page::Services => self.page_services(),
            Page::Network => self.page_network(),
            Page::Tools => self.page_tools(),
            Page::Vault => self.page_vault(),
        };

        let content = column![nav, body]
            .spacing(12)
            .padding(12);
        container(content)
            .width(iced::Length::Fill)
            .height(iced::Length::Fill)
            .center_x().center_y()
            .into()
    }

    fn theme(&self) -> Theme { Theme::Dark }

    fn run(settings: Settings<()>) -> iced::Result {
        let mut settings = settings; settings.window.size=(800,480); settings.window.decorations=false; settings.window.maximized=true; Self::run(settings)
    }
}

impl App {
    fn page_services(&self) -> Element<Msg> {
        let mut svc = row![] .spacing(8).align_items(Alignment::Center);
        for &s in SERVICES { svc = svc
            .push(button(text(format!("▶ {}", s))).on_press(Msg::SvcAction(Action::Start, s)))
            .push(button(text("⟳").size(20)).on_press(Msg::SvcAction(Action::Restart, s)))
            .push(button(text("■")).on_press(Msg::SvcAction(Action::Stop, s)))
            .push(Space::with_width(8)); }
        column![svc, scrollable(container(text(self.status.clone()).size(16)).padding(12)).height(iced::Length::Fill)].into()
    }

    fn page_network(&self) -> Element<Msg> {
        let nat = row![
            text("NAT (Internet Sharing)"),
            Space::with_width(16),
            toggler(Some("off".into()), self.nat_enabled, Msg::NatToggle),
            Space::with_width(16),
            text("Uplink:"),
            pick_list(UPLINKS, Some(self.uplink), Msg::UplinkPick),
            Space::with_width(16),
            text(format!("TARGET: {}", if self.target_ip.is_empty(){"unknown"}else{&self.target_ip})),
        ].spacing(12).align_items(Alignment::Center);
        column![nat].into()
    }

    fn page_tools(&self) -> Element<Msg> {
        let tools = row![
            button(text("Ensure USB Gadget" )).on_press(Msg::UsbEnsure),
            Space::with_width(8),
            button(text("Find TARGET IP")).on_press(Msg::Refresh),
            Space::with_width(8),
            button(text("Start Serial TCP (5555) → /dev/ttyGS0")).on_press(Msg::SvcAction(Action::Start, "target-serial-tcp")),
        ].spacing(10).align_items(Alignment::Center);
        column![tools].into()
    }

    fn page_vault(&self) -> Element<Msg> {
        column![ text("Vault: configure pass/age/YubiKey in backend (TODO hooks)."), ].into()
    }
}

fn parse_text(body: &str) -> String {
    if let Ok(v) = serde_json::from_str::<serde_json::Value>(body) { if v.get("ok").and_then(|b| b.as_bool())==Some(true) { if let Some(t)=v.get("data").and_then(|d|d.get("text")).and_then(|t|t.as_str()){ return t.to_string(); } } if let Some(e)=v.get("error").and_then(|t|t.as_str()){ return format!("error: {}", e); } } body.to_string()
}

fn load_status() -> Command<Msg> { Command::perform(async move { match ureq::get(&format!("{}/api/status/services", API)).call(){ Ok(r)=>r.into_string().map_err(|e|e.to_string()), Err(e)=>Err(e.to_string()), } }, |r| match r { Ok(b)=>Msg::StatusLoaded(parse_text(&b)), Err(e)=>Msg::Done(Err(e)), }) }
fn load_logs() -> Command<Msg> { Command::perform(async move { match ureq::get(&format!("{}/api/logs", API)).call(){ Ok(r)=>r.into_string().map_err(|e|e.to_string()), Err(e)=>Err(e.to_string()), } }, |r| match r { Ok(b)=>Msg::LogsLoaded(parse_text(&b)), Err(e)=>Msg::Done(Err(e)), }) }
fn find_target_ip() -> Command<Msg> { Command::perform(async move { match ureq::get(&format!("{}/api/target/ip", API)).call(){ Ok(r)=>r.into_string().map_err(|e|e.to_string()), Err(e)=>Err(e.to_string()), } }, |r| match r{ Ok(b)=>Msg::TargetFound(parse_text(&b)), Err(_)=>Msg::TargetFound(String::new()), }) }

fn svc_command(action: Action, svc: &'static str) -> Command<Msg> {
    Command::perform(async move {
        let body = serde_json::to_string(&SvcReq { name: svc }).unwrap();
        let endpoint = match action { Action::Start=>"start", Action::Stop=>"stop", Action::Restart=>"restart" };
        let req = ureq::post(&format!("{}/api/svc/{}", API, endpoint)).set("Content-Type","application/json").send_string(&body);
        match req { Ok(resp)=>resp.into_string().map_err(|e|e.to_string()), Err(e)=>Err(e.to_string()) }
    }, |res| match res { Ok(body)=>Msg::Done(Ok(parse_text(&body))), Err(e)=>Msg::Done(Err(e)), })
}

fn nat_toggle(on: bool, uplink: &'static str) -> Command<Msg> { Command::perform(async move {
    let body = serde_json::to_string(&NatReq{ uplink: Some(uplink) }).unwrap();
    let action = if on {"on"} else {"off"};
    let req = ureq::post(&format!("{}/api/nat/{}", API, action)).set("Content-Type","application/json").send_string(&body);
    match req { Ok(resp)=>resp.into_string().map_err(|e|e.to_string()), Err(e)=>Err(e.to_string()) }
}, |res| match res { Ok(body)=>Msg::NatDone(Ok(parse_text(&body))), Err(e)=>Msg::NatDone(Err(e)), }) }

fn usb_ensure() -> Command<Msg> { Command::perform(async move {
    let req = ureq::post(&format!("{}/api/usb/ensure", API)).call();
    match req { Ok(resp)=>resp.into_string().map_err(|e|e.to_string()), Err(e)=>Err(e.to_string()) }
}, |res| match res { Ok(body)=>Msg::Done(Ok(parse_text(&body))), Err(e)=>Msg::Done(Err(e)), }) }
