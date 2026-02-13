use vte::{Parser, Perform};

/// VT100/ANSI escape sequence parser wrapping `vte` crate.
/// Tracks cursor position, text attributes, and screen content.
pub struct VtEmulator {
    parser: Parser,
    pub cursor_x: usize,
    pub cursor_y: usize,
    pub cols: usize,
    pub rows: usize,
    /// Screen buffer: rows x cols of characters
    pub cells: Vec<Vec<Cell>>,
}

/// A single cell in the terminal grid.
#[derive(Clone, Debug)]
pub struct Cell {
    pub ch: char,
    pub fg: Color,
    pub bg: Color,
    pub bold: bool,
    pub underline: bool,
}

/// Terminal color representation.
#[derive(Clone, Debug, Copy)]
pub enum Color {
    Default,
    Indexed(u8),
    Rgb(u8, u8, u8),
}

impl Default for Cell {
    fn default() -> Self {
        Self {
            ch: ' ',
            fg: Color::Default,
            bg: Color::Default,
            bold: false,
            underline: false,
        }
    }
}

impl VtEmulator {
    pub fn new(cols: usize, rows: usize) -> Self {
        let cells = vec![vec![Cell::default(); cols]; rows];
        Self {
            parser: Parser::new(),
            cursor_x: 0,
            cursor_y: 0,
            cols,
            rows,
            cells,
        }
    }

    /// Feed raw bytes from PTY into the VT parser.
    pub fn process(&mut self, bytes: &[u8]) {
        let mut performer = EmulatorPerformer {
            cursor_x: &mut self.cursor_x,
            cursor_y: &mut self.cursor_y,
            cols: self.cols,
            rows: self.rows,
            cells: &mut self.cells,
        };
        self.parser.advance(&mut performer, bytes);
    }

    /// Resize the emulator grid.
    pub fn resize(&mut self, cols: usize, rows: usize) {
        self.cols = cols;
        self.rows = rows;
        self.cells.resize(rows, vec![Cell::default(); cols]);
        for row in self.cells.iter_mut() {
            row.resize(cols, Cell::default());
        }
        if self.cursor_x >= cols {
            self.cursor_x = cols - 1;
        }
        if self.cursor_y >= rows {
            self.cursor_y = rows - 1;
        }
    }

    /// Get the text content of a specific line.
    pub fn get_line_text(&self, row: usize) -> String {
        if row < self.cells.len() {
            self.cells[row].iter().map(|c| c.ch).collect()
        } else {
            String::new()
        }
    }
}

/// Internal performer that implements vte::Perform.
struct EmulatorPerformer<'a> {
    cursor_x: &'a mut usize,
    cursor_y: &'a mut usize,
    cols: usize,
    rows: usize,
    cells: &'a mut Vec<Vec<Cell>>,
}

impl<'a> EmulatorPerformer<'a> {
    fn scroll_up(&mut self) {
        self.cells.remove(0);
        self.cells.push(vec![Cell::default(); self.cols]);
    }

    fn newline(&mut self) {
        *self.cursor_x = 0;
        if *self.cursor_y + 1 >= self.rows {
            self.scroll_up();
        } else {
            *self.cursor_y += 1;
        }
    }
}

impl<'a> Perform for EmulatorPerformer<'a> {
    fn print(&mut self, ch: char) {
        if *self.cursor_x >= self.cols {
            self.newline();
        }
        if *self.cursor_y < self.cells.len() && *self.cursor_x < self.cols {
            self.cells[*self.cursor_y][*self.cursor_x].ch = ch;
            *self.cursor_x += 1;
        }
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            // Newline (LF)
            b'\n' | 0x0b | 0x0c => {
                if *self.cursor_y + 1 >= self.rows {
                    self.scroll_up();
                } else {
                    *self.cursor_y += 1;
                }
            }
            // Carriage return
            b'\r' => {
                *self.cursor_x = 0;
            }
            // Backspace
            0x08 => {
                if *self.cursor_x > 0 {
                    *self.cursor_x -= 1;
                }
            }
            // Tab
            b'\t' => {
                let next_tab = (*self.cursor_x / 8 + 1) * 8;
                *self.cursor_x = next_tab.min(self.cols - 1);
            }
            // Bell
            0x07 => { /* TODO: visual bell */ }
            _ => {}
        }
    }

    fn hook(&mut self, _params: &vte::Params, _intermediates: &[u8], _ignore: bool, _action: char) {}
    fn put(&mut self, _byte: u8) {}
    fn unhook(&mut self) {}

    fn osc_dispatch(&mut self, _params: &[&[u8]], _bell_terminated: bool) {
        // TODO: handle OSC sequences (window title, clipboard, etc.)
    }

    fn csi_dispatch(&mut self, params: &vte::Params, _intermediates: &[u8], _ignore: bool, action: char) {
        let mut params_iter = params.iter();
        let first = params_iter.next().and_then(|p| p.first().copied()).unwrap_or(0);
        let second = params_iter.next().and_then(|p| p.first().copied()).unwrap_or(0);

        match action {
            // Cursor Up
            'A' => {
                let n = if first == 0 { 1 } else { first as usize };
                *self.cursor_y = self.cursor_y.saturating_sub(n);
            }
            // Cursor Down
            'B' => {
                let n = if first == 0 { 1 } else { first as usize };
                *self.cursor_y = (*self.cursor_y + n).min(self.rows - 1);
            }
            // Cursor Forward
            'C' => {
                let n = if first == 0 { 1 } else { first as usize };
                *self.cursor_x = (*self.cursor_x + n).min(self.cols - 1);
            }
            // Cursor Back
            'D' => {
                let n = if first == 0 { 1 } else { first as usize };
                *self.cursor_x = self.cursor_x.saturating_sub(n);
            }
            // Cursor Position (H or f)
            'H' | 'f' => {
                let row = if first == 0 { 1 } else { first as usize };
                let col = if second == 0 { 1 } else { second as usize };
                *self.cursor_y = (row - 1).min(self.rows - 1);
                *self.cursor_x = (col - 1).min(self.cols - 1);
            }
            // Erase in Display
            'J' => {
                match first {
                    0 => {
                        // Clear from cursor to end of screen
                        for x in *self.cursor_x..self.cols {
                            self.cells[*self.cursor_y][x] = Cell::default();
                        }
                        for y in (*self.cursor_y + 1)..self.rows {
                            for x in 0..self.cols {
                                self.cells[y][x] = Cell::default();
                            }
                        }
                    }
                    1 => {
                        // Clear from start to cursor
                        for y in 0..*self.cursor_y {
                            for x in 0..self.cols {
                                self.cells[y][x] = Cell::default();
                            }
                        }
                        for x in 0..=*self.cursor_x {
                            self.cells[*self.cursor_y][x] = Cell::default();
                        }
                    }
                    2 | 3 => {
                        // Clear entire screen
                        for y in 0..self.rows {
                            for x in 0..self.cols {
                                self.cells[y][x] = Cell::default();
                            }
                        }
                    }
                    _ => {}
                }
            }
            // Erase in Line
            'K' => {
                match first {
                    0 => {
                        for x in *self.cursor_x..self.cols {
                            self.cells[*self.cursor_y][x] = Cell::default();
                        }
                    }
                    1 => {
                        for x in 0..=*self.cursor_x {
                            self.cells[*self.cursor_y][x] = Cell::default();
                        }
                    }
                    2 => {
                        for x in 0..self.cols {
                            self.cells[*self.cursor_y][x] = Cell::default();
                        }
                    }
                    _ => {}
                }
            }
            _ => {
                // TODO: handle more CSI sequences (SGR, scroll, etc.)
            }
        }
    }

    fn esc_dispatch(&mut self, _intermediates: &[u8], _ignore: bool, _byte: u8) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_print_basic() {
        let mut emu = VtEmulator::new(80, 24);
        emu.process(b"Hello, Pier!");
        assert_eq!(emu.get_line_text(0).trim(), "Hello, Pier!");
        assert_eq!(emu.cursor_x, 12);
        assert_eq!(emu.cursor_y, 0);
    }

    #[test]
    fn test_newline() {
        let mut emu = VtEmulator::new(80, 24);
        emu.process(b"Line1\r\nLine2");
        assert_eq!(emu.get_line_text(0).trim(), "Line1");
        assert_eq!(emu.get_line_text(1).trim(), "Line2");
    }

    #[test]
    fn test_cursor_movement() {
        let mut emu = VtEmulator::new(80, 24);
        // ESC[5;10H moves cursor to row 5, col 10
        emu.process(b"\x1b[5;10HX");
        assert_eq!(emu.cells[4][9].ch, 'X');
    }

    #[test]
    fn test_clear_screen() {
        let mut emu = VtEmulator::new(80, 24);
        emu.process(b"Some text");
        emu.process(b"\x1b[2J");
        assert_eq!(emu.get_line_text(0).trim(), "");
    }
}
