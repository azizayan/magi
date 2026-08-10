pub mod markdown;

#[derive(Debug, Default)]
pub struct ReaderState {
    content: String,
    last_seen: Option<String>,
    listening: bool,
}

impl ReaderState {
    pub fn new(initial_clipboard: Option<String>) -> Self {
        Self {
            last_seen: initial_clipboard,
            listening: false,
            ..Self::default()
        }
    }

    pub fn content(&self) -> &str {
        &self.content
    }

    pub fn is_empty(&self) -> bool {
        self.content.is_empty()
    }

    pub fn is_listening(&self) -> bool {
        self.listening
    }

    pub fn set_listening(&mut self, listening: bool) {
        self.listening = listening;
    }

    pub fn clear_content(&mut self) {
        self.content.clear();
    }

    pub fn baseline_clipboard(&mut self, text: String) {
        self.last_seen = Some(text);
    }

    pub fn observe_clipboard(&mut self, text: String) -> bool {
        if self.last_seen.as_deref() == Some(text.as_str()) {
            return false;
        }

        self.last_seen = Some(text.clone());
        if !self.listening || text.trim().is_empty() {
            return false;
        }

        self.content = text;
        true
    }

    pub fn capture_now(&mut self, text: String) -> bool {
        self.last_seen = Some(text.clone());
        if text.trim().is_empty() {
            return false;
        }

        self.content = text;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::ReaderState;

    #[test]
    fn startup_clipboard_is_only_a_baseline() {
        let state = ReaderState::new(Some("older copy".into()));
        assert!(state.is_empty());
        assert!(!state.is_listening());
    }

    #[test]
    fn a_new_copy_replaces_the_reader_content() {
        let mut state = ReaderState::new(Some("old".into()));
        state.set_listening(true);
        assert!(state.observe_clipboard("first response".into()));
        assert!(state.observe_clipboard("second response".into()));
        assert_eq!(state.content(), "second response");
    }

    #[test]
    fn repeated_or_blank_clipboard_content_is_ignored() {
        let mut state = ReaderState::new(None);
        state.set_listening(true);
        assert!(state.observe_clipboard("response".into()));
        assert!(!state.observe_clipboard("response".into()));
        assert!(!state.observe_clipboard("  \n".into()));
        assert_eq!(state.content(), "response");
    }

    #[test]
    fn pausing_stops_automatic_replacement() {
        let mut state = ReaderState::new(None);
        assert!(!state.observe_clipboard("unrelated copy".into()));
        assert!(state.is_empty());
    }

    #[test]
    fn capture_now_works_while_paused() {
        let mut state = ReaderState::new(None);
        assert!(state.capture_now("chosen response".into()));
        assert_eq!(state.content(), "chosen response");
    }

    #[test]
    fn copying_from_the_reader_does_not_replace_its_content() {
        let mut state = ReaderState::new(None);
        state.capture_now("complete response".into());

        state.baseline_clipboard("selected words".into());
        assert!(!state.observe_clipboard("selected words".into()));
        assert_eq!(state.content(), "complete response");

        state.set_listening(true);
        assert!(state.observe_clipboard("next source response".into()));
        assert_eq!(state.content(), "next source response");
    }

    #[test]
    fn clear_discards_displayed_content() {
        let mut state = ReaderState::new(None);
        state.capture_now("sensitive response".into());

        state.clear_content();

        assert!(state.is_empty());
    }
}
