use pulldown_cmark::{Event, HeadingLevel, Parser, Tag, TagEnd};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpanKind {
    Prose,
    Heading(u8),
    Code,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Span {
    pub text: String,
    pub kind: SpanKind,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct RenderedMarkdown {
    pub spans: Vec<Span>,
}

impl RenderedMarkdown {
    pub fn parse(markdown: &str) -> Self {
        let mut renderer = Renderer::default();
        for event in Parser::new(markdown) {
            renderer.event(event);
        }
        renderer.finish()
    }

    pub fn plain_text(&self) -> String {
        self.spans.iter().map(|span| span.text.as_str()).collect()
    }
}

#[derive(Debug)]
struct ListState {
    next_number: Option<u64>,
}

#[derive(Debug, Default)]
struct Renderer {
    output: RenderedMarkdown,
    heading: Option<u8>,
    in_code_block: bool,
    lists: Vec<ListState>,
}

impl Renderer {
    fn event(&mut self, event: Event<'_>) {
        match event {
            Event::Start(Tag::Heading { level, .. }) => {
                self.heading = Some(heading_level(level));
            }
            Event::End(TagEnd::Heading(_)) => {
                self.push("\n\n", self.kind());
                self.heading = None;
            }
            Event::Start(Tag::CodeBlock(_)) => self.in_code_block = true,
            Event::End(TagEnd::CodeBlock) => {
                self.push("\n\n", SpanKind::Code);
                self.in_code_block = false;
            }
            Event::Start(Tag::List(first)) => {
                if !self.lists.is_empty() {
                    self.ensure_line_break();
                }
                self.lists.push(ListState { next_number: first });
            }
            Event::End(TagEnd::List(_)) => {
                self.lists.pop();
                if self.lists.is_empty() {
                    self.ensure_break();
                } else {
                    self.ensure_line_break();
                }
            }
            Event::Start(Tag::Item) => self.push_list_marker(),
            Event::End(TagEnd::Item) => self.ensure_line_break(),
            Event::End(TagEnd::Paragraph) => self.ensure_break(),
            Event::Start(Tag::BlockQuote(_)) => self.push("│ ", SpanKind::Prose),
            Event::Text(text) => self.push(&text, self.kind()),
            Event::Code(code) => self.push(&code, SpanKind::Code),
            Event::SoftBreak => {
                let separator = if self.in_code_block { "\n" } else { " " };
                self.push(separator, self.kind());
            }
            Event::HardBreak => self.push("\n", self.kind()),
            Event::Rule => self.push("────────\n", SpanKind::Prose),
            Event::TaskListMarker(done) => {
                self.push(if done { "☑ " } else { "☐ " }, SpanKind::Prose);
            }
            Event::InlineMath(value) | Event::DisplayMath(value) => {
                self.push(&value, SpanKind::Code);
            }
            Event::FootnoteReference(label) => {
                self.push(&format!("[{label}]"), SpanKind::Prose);
            }
            Event::Html(_) | Event::InlineHtml(_) | Event::End(_) | Event::Start(_) => {}
        }
    }

    fn kind(&self) -> SpanKind {
        if self.in_code_block {
            SpanKind::Code
        } else if let Some(level) = self.heading {
            SpanKind::Heading(level)
        } else {
            SpanKind::Prose
        }
    }

    fn push_list_marker(&mut self) {
        let indent = "  ".repeat(self.lists.len().saturating_sub(1));
        let marker = match self
            .lists
            .last_mut()
            .and_then(|list| list.next_number.as_mut())
        {
            Some(number) => {
                let marker = format!("{number}. ");
                *number += 1;
                marker
            }
            None => "• ".to_owned(),
        };
        self.push(&format!("{indent}{marker}"), SpanKind::Prose);
    }

    fn push(&mut self, text: &str, kind: SpanKind) {
        if text.is_empty() {
            return;
        }
        if let Some(last) = self.output.spans.last_mut()
            && last.kind == kind
        {
            last.text.push_str(text);
            return;
        }
        self.output.spans.push(Span {
            text: text.to_owned(),
            kind,
        });
    }

    fn ensure_line_break(&mut self) {
        if !self.output.plain_text().ends_with('\n') {
            self.push("\n", SpanKind::Prose);
        }
    }

    fn ensure_break(&mut self) {
        let text = self.output.plain_text();
        if text.ends_with("\n\n") {
            return;
        }
        if text.ends_with('\n') {
            self.push("\n", SpanKind::Prose);
        } else {
            self.push("\n\n", SpanKind::Prose);
        }
    }

    fn finish(mut self) -> RenderedMarkdown {
        while self.output.plain_text().ends_with('\n') {
            let Some(last) = self.output.spans.last_mut() else {
                break;
            };
            last.text.pop();
            if last.text.is_empty() {
                self.output.spans.pop();
            }
        }
        self.output
    }
}

fn heading_level(level: HeadingLevel) -> u8 {
    match level {
        HeadingLevel::H1 => 1,
        HeadingLevel::H2 => 2,
        HeadingLevel::H3 => 3,
        HeadingLevel::H4 => 4,
        HeadingLevel::H5 => 5,
        HeadingLevel::H6 => 6,
    }
}

#[cfg(test)]
mod tests {
    use super::{RenderedMarkdown, SpanKind};

    #[test]
    fn renders_headings_lists_and_code_as_readable_text() {
        let rendered = RenderedMarkdown::parse(
            "# Result\n\n- first\n- second with `inline`\n\n```rust\nlet x = 1;\n```",
        );

        assert_eq!(
            rendered.plain_text(),
            "Result\n\n• first\n• second with inline\n\nlet x = 1;"
        );
        assert!(
            rendered
                .spans
                .iter()
                .any(|span| { span.kind == SpanKind::Heading(1) && span.text.contains("Result") })
        );
        assert!(
            rendered
                .spans
                .iter()
                .any(|span| { span.kind == SpanKind::Code && span.text.contains("let x = 1;") })
        );
    }

    #[test]
    fn preserves_numbering_and_nested_list_indentation() {
        let rendered = RenderedMarkdown::parse("3. three\n   - nested\n4. four");
        assert_eq!(rendered.plain_text(), "3. three\n  • nested\n4. four");
    }

    #[test]
    fn plain_text_is_unchanged_when_there_is_no_markdown() {
        let rendered = RenderedMarkdown::parse("A plain response with punctuation.");
        assert_eq!(rendered.plain_text(), "A plain response with punctuation.");
    }
}
