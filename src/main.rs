#![allow(unused_must_use, dead_code)]

use clap::Parser;
use crossterm::style::{PrintStyledContent, Stylize};
use crossterm::{
    cursor,
    event::{self, read, Event, KeyCode, KeyEvent, KeyModifiers},
    terminal::{self, EnterAlternateScreen, LeaveAlternateScreen},
    ExecutableCommand, QueueableCommand,
};
use std::fs::File;
use std::io::BufRead;
use std::path::{Path, PathBuf};
use std::usize;
use std::{
    collections::HashMap,
    io::{stdout, Write},
};

#[derive(Clone, Debug, Copy, Hash)]
enum Direction {
    Left,
    Right,
    Up,
    Down,
}

#[derive(Clone, Debug, Copy, Hash)]
enum ToriEvent {
    Quit,
    Move(Direction),
}

struct Config {
    /// Vertical croll lookahead
    lookahead: u16,
}

impl Config {
    pub fn default() -> Self {
        Self { lookahead: 6 }
    }
}

type KeyMap = HashMap<event::KeyEvent, ToriEvent>;

fn default_keymap() -> KeyMap {
    let mut keymap = HashMap::new();
    keymap.insert(
        KeyEvent::new(KeyCode::Char('q'), KeyModifiers::empty()),
        ToriEvent::Quit,
    );

    // Movement with arrow keys
    keymap.insert(
        KeyEvent::new(KeyCode::Left, KeyModifiers::empty()),
        ToriEvent::Move(Direction::Left),
    );
    keymap.insert(
        KeyEvent::new(KeyCode::Right, KeyModifiers::empty()),
        ToriEvent::Move(Direction::Right),
    );
    keymap.insert(
        KeyEvent::new(KeyCode::Up, KeyModifiers::empty()),
        ToriEvent::Move(Direction::Up),
    );
    keymap.insert(
        KeyEvent::new(KeyCode::Down, KeyModifiers::empty()),
        ToriEvent::Move(Direction::Down),
    );

    keymap
}

// A buffer that is able to hold textual content.
struct FileBuffer {
    /// Flag indicating if the content has been modified since last save.
    is_modified: bool,
    /// Path to the file where the buffer is saved to.
    path: PathBuf,
    /// Textual content of this buffer.
    content: Vec<String>,
    /// Horizontal position of cursor within the content of this buffer. zero is left.
    cursor_x: u16,
    /// The desired horizontal cursor offset. Used to retain x offset while moving vertically.
    desired_cursor_x: u16,
    /// Vertical position of cursor within the content of this buffer. zero is top.
    cursor_y: u16,
    /// Horizontal scroll offset of this buffer.
    scroll_x: u16,
    /// Vertical scroll offset of this buffer.
    scroll_y: u16,
}

impl FileBuffer {
    /// Creates a [Buffer] by reading the file at path.
    pub fn read_from_path(path: &Path) -> std::io::Result<FileBuffer> {
        let file = File::open(path)?;
        let reader = std::io::BufReader::new(file).lines();
        let content = reader.collect::<Result<Vec<String>, std::io::Error>>()?;
        Ok(Self {
            is_modified: false,
            path: path.to_path_buf(),
            content,
            cursor_y: 0,
            cursor_x: 0,
            desired_cursor_x: 0,
            scroll_y: 0,
            scroll_x: 0,
        })
    }

    // Returns the amount of lines in this file buffer.
    pub fn line_count(&self) -> u16 {
        u16::try_from(self.content.len()).unwrap_or(u16::MAX)
    }

    // Returns the number of digits in the line count of this file buffer.
    pub fn max_line_length(&self) -> u16 {
        // Unwrap is safe here since a u16 cannot have more digits that its max value.
        // That is, u16::MAX = 65535 only has 5 digits.
        u16::try_from(self.line_count().to_string().len()).unwrap()
    }

    // Gets the length of af line.
    pub fn line_width(&self, line_idx: usize) -> u16 {
        u16::try_from(
            self.content
                .get(line_idx)
                .map(|line| line.len())
                .unwrap_or(0),
        )
        .unwrap_or(0)
    }
}

/// Editor state of Tori.
struct Tori {
    /// Flag indicating that Tori should quit on the next update.
    should_quit: bool,
    /// Bindings between [KeyEvent]s and [ToriEvent]s.
    keymap: KeyMap,
    /// Editor configuration struct.
    config: Config,
    /// Active buffer.
    buffer: FileBuffer,
    /// Width of the attached terminal.
    columns: u16,
    /// Height of the attached terminal.
    rows: u16,
    /// Width of the screen the buffer gets rendered to.
    screen_rows: u16,
    /// Height of the screen the buffer gets rendered to.
    screen_columns: u16,
}

impl Tori {
    pub fn new(buffer: FileBuffer) -> Self {
        let (columns, rows) = terminal::size().unwrap_or((0, 0));
        let mut instance = Self {
            should_quit: false,
            columns,
            rows,
            config: Config::default(),
            keymap: default_keymap(),
            buffer,
            screen_rows: 0,
            screen_columns: 0,
        };
        instance.update_screen_size();
        instance
    }

    fn update_screen_size(&mut self) {
        self.screen_columns = self.columns - (self.buffer.max_line_length() + 1);
        self.screen_rows = self.rows - 1;
    }

    /// Moves cursor x to the desired spot or the end of line, whichever is smaller.
    fn move_cursor_x_to_desired(&mut self) {
        self.buffer.cursor_x = self.buffer.desired_cursor_x;
        self.buffer.cursor_x = self
            .buffer
            .cursor_x
            .min(self.buffer.line_width(self.buffer.cursor_y.into()));
    }

    /// Maintains horizontal and vertical scroll of the current buffer.
    fn maintain_scroll(&mut self) {
        let cy = self.buffer.cursor_y;
        let cx = self.buffer.cursor_x;
        let sy = self.buffer.scroll_y;
        let sx = self.buffer.scroll_x;

        // Scroll up if needed.
        if cy - self.config.lookahead < sy {
            self.buffer.scroll_y = (cy - self.config.lookahead).max(0);
        }
        // Scroll down if needed.
        if cy + self.config.lookahead >= sy + self.screen_rows {
            self.buffer.scroll_y =
                (cy + self.config.lookahead).min(self.buffer.line_count() - 1) - self.screen_rows;
        }
        // Scroll left if needed.
        if cx < sx {
            self.buffer.scroll_x = cx;
        }
        // Scroll right if needed.
        if cx >= sx + self.screen_columns {
            self.buffer.scroll_x = cx - self.screen_columns + 1;
        }
    }

    fn dispatch(&mut self, event: ToriEvent) {
        use Direction::*;
        match event {
            ToriEvent::Quit => self.should_quit = true,
            ToriEvent::Move(Up) => {
                self.buffer.cursor_y = self.buffer.cursor_y.max(1) - 1;
                self.move_cursor_x_to_desired();
                self.maintain_scroll();
            }
            ToriEvent::Move(Down) => {
                self.buffer.cursor_y = (self.buffer.cursor_y + 1).min(self.buffer.line_count() - 1);
                self.move_cursor_x_to_desired();
                self.maintain_scroll();
            }
            ToriEvent::Move(Left) => {
                // Wrap to previus line if needed
                let should_wrap = self.buffer.cursor_x == 0;
                if should_wrap {
                    // Do the wrap by moving up and then to the end of line.
                    self.dispatch(ToriEvent::Move(Up));
                    self.buffer.cursor_x = self.buffer.line_width(self.buffer.cursor_y.into());
                } else {
                    self.buffer.cursor_x = self.buffer.cursor_x.max(1) - 1;
                }
                self.buffer.desired_cursor_x = self.buffer.cursor_x;
                self.maintain_scroll();
            }
            ToriEvent::Move(Right) => {
                let cx = self.buffer.cursor_x;
                let line_width = self.buffer.line_width(self.buffer.cursor_y.into());
                // Wrap to next line if needed.
                let should_wrap = line_width <= cx;
                if should_wrap {
                    // Do the wrap by moving to start of line and down.
                    self.buffer.scroll_x = 0;
                    self.buffer.cursor_x = 0;
                    self.buffer.desired_cursor_x = 0;
                    self.dispatch(ToriEvent::Move(Down));
                } else {
                    self.buffer.cursor_x = (cx + 1).min(line_width);
                    self.buffer.desired_cursor_x = self.buffer.cursor_x;
                }
                self.maintain_scroll();
            }
        }
    }

    fn handle_input(&mut self) -> std::io::Result<()> {
        match read()? {
            Event::Resize(columns, rows) => {
                self.columns = columns;
                self.rows = rows;
                self.update_screen_size();
            }
            Event::Key(event) => {
                // Ignore release events.
                if event.kind == event::KeyEventKind::Release {
                    return Ok(());
                }

                // Lookup keyboard event in keymap and dispatch it.
                if let Some(event) = self.keymap.get(&event) {
                    self.dispatch(*event);
                }
            }
            _ => {}
        }
        Ok(())
    }

    /// Draws the current editor state to the screen
    fn draw(&mut self) -> std::io::Result<()> {
        let mut stdout = stdout();
        // Clear the screen
        stdout.queue(terminal::Clear(terminal::ClearType::All));

        // Draw content
        stdout.queue(cursor::MoveTo(0, 0));
        // Get the lines that fit in the current window.
        let line_number_width = self.buffer.max_line_length();
        let from = usize::from(self.buffer.scroll_y);
        let to = from + usize::from(self.screen_rows);
        for idx in from..to {
            let mut line_content = if let Some(line) = self.buffer.content.get(idx) {
                let from = usize::from(self.buffer.scroll_x).min(line.len());
                let to = (from + usize::from(self.screen_columns)).min(line.len());
                format!(
                    "{:>width$} {}",
                    idx + 1,
                    &line[from..to],
                    width = usize::from(line_number_width)
                )
            } else {
                "~".to_string()
            };
            line_content.truncate(self.columns.into());
            if idx < to - 1 {
                line_content += "\r\n"
            }
            stdout.queue(PrintStyledContent(line_content.white()));
        }

        // place cursor
        // Offset cursor horizontally by the width of the line numbers.
        let cx = self.buffer.cursor_x + line_number_width + 1 - self.buffer.scroll_x;
        let cy = self.buffer.cursor_y - self.buffer.scroll_y;
        stdout.queue(cursor::MoveTo(cx, cy));

        // Actually flush the commands to stdout
        stdout.flush()
    }

    /// Performs one update tick.
    pub fn update(&mut self) -> std::io::Result<()> {
        self.handle_input()?;
        self.draw()
    }

    pub fn run(&mut self) -> std::io::Result<()> {
        let mut stdout = stdout();

        // Enable raw mode and enter alternate screen so the terminal isn't polluted.
        terminal::enable_raw_mode();
        stdout.execute(EnterAlternateScreen)?;

        // Draw the first frame.
        self.draw()?;

        // Run the update loop until the editor is done.
        while !self.should_quit {
            self.update();
        }

        // Leave alternate screen and raw mode to leave user back at where they were.
        std::io::stdout().execute(LeaveAlternateScreen)?;
        terminal::disable_raw_mode()
    }
}

const VERSION: &str = "0.1.0";

#[derive(Parser)]
#[command(
    version = VERSION,
    about,
    long_about = "A terminal editor with wings! 🐦"
)]
struct Cli {
    /// The file to be loaded.
    file_path: PathBuf,
}

fn main() {
    // Read file from arguments into a FileBuffer and run tori on it.
    let args = Cli::parse();
    match FileBuffer::read_from_path(args.file_path.as_path()) {
        Ok(buffer) => {
            let mut tori = Tori::new(buffer);
            tori.run();
        }
        Err(err) => println!("{err}"),
    }
}
