use aho_corasick::{AhoCorasick, AhoCorasickBuilder, MatchKind};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AdSegment {
    pub start_time: f64,
    pub end_time: f64,
    pub confidence: f32,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TimedWord {
    pub word: String,
    pub start_time: f64,
    pub end_time: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Chapter {
    pub title: String,
    pub start_time: f64,
    pub end_time: f64,
}

pub struct AdSkipEngine {
    trigger_matcher: AhoCorasick,
    exit_matcher: AhoCorasick,
    trigger_phrases: Vec<String>,
    exit_phrases: Vec<String>,
    chapter_ad_regex: Regex,
    stream_tokens: VecDeque<TimedWord>,
    max_stream_window_secs: f64,
    current_ad_start: Option<f64>,
}

impl Default for AdSkipEngine {
    fn default() -> Self {
        Self::new()
    }
}

impl AdSkipEngine {
    pub fn new() -> Self {
        let trigger_phrases = vec![
            "sponsored by".to_string(),
            "support for this podcast comes from".to_string(),
            "support for this podcast".to_string(),
            "support for this show".to_string(),
            "support this podcast".to_string(),
            "support this show".to_string(),
            "products and services that support".to_string(),
            "products and services".to_string(),
            "a word from our sponsor".to_string(),
            "today's sponsor".to_string(),
            "todays sponsor".to_string(),
            "brought to you by".to_string(),
            "promo code".to_string(),
            "use code".to_string(),
            "use the code".to_string(),
            "with code".to_string(),
            "discount code".to_string(),
            "special offer".to_string(),
            "head over to".to_string(),
            "go to".to_string(),
            "visit".to_string(),
            "check out".to_string(),
            "for 20% off".to_string(),
            "for 10% off".to_string(),
            "for 15% off".to_string(),
            "10% off".to_string(),
            "15% off".to_string(),
            "20% off".to_string(),
            "25% off".to_string(),
            "30% off".to_string(),
            "50% off".to_string(),
            "percent off".to_string(),
            "% off".to_string(),
            "free shipping".to_string(),
            "risk-free".to_string(),
            "money-back guarantee".to_string(),
            "terms and conditions apply".to_string(),
            "terms and conditions".to_string(),
            "at checkout".to_string(),
            "sign up today".to_string(),
            "download the app".to_string(),
            "gambling problem".to_string(),
            "1-800-gambler".to_string(),
            "call 1-800".to_string(),
            "fdic insured".to_string(),
            "equal housing".to_string(),
            "we'll be right back".to_string(),
            "well be right back".to_string(),
            "after these ads".to_string(),
            "quick ad break".to_string(),
            "a quick ad break".to_string(),
            "take a quick ad break".to_string(),
            "a quick break".to_string(),
            "ad break".to_string(),
            "here's some ads".to_string(),
            "heres some ads".to_string(),
            "here are some ads".to_string(),
            "here are the ads".to_string(),
            "here's the ads".to_string(),
            "heres the ads".to_string(),
            "let's go to some ads".to_string(),
            "lets go to some ads".to_string(),
            "let's go to ads".to_string(),
            "lets go to ads".to_string(),
            "we have to go to ads".to_string(),
            "have to go to ads".to_string(),
            "time for some ads".to_string(),
            "time for ads".to_string(),
            "time for an ad".to_string(),
            "time for a sponsor".to_string(),
            "let's take a break".to_string(),
            "lets take a break".to_string(),
            "let's take a quick break".to_string(),
            "lets take a quick break".to_string(),
            "take a quick break".to_string(),
            "take a break".to_string(),
            "we're gonna take a break".to_string(),
            "were gonna take a break".to_string(),
            "we're going to take a break".to_string(),
            "we are going to take a break".to_string(),
            "products and services that support this podcast".to_string(),
            "products and services that support the show".to_string(),
            "products and services that support this show".to_string(),
            "products and services that keep the lights on".to_string(),
            "the products and services".to_string(),
            "these products and services".to_string(),
            "a word from our sponsors".to_string(),
            "word from our sponsors".to_string(),
            "word from our sponsor".to_string(),
            "messages from our sponsors".to_string(),
            "message from our sponsors".to_string(),
            "message from our sponsor".to_string(),
            "take an ad break".to_string(),
            "sponsor break".to_string(),
            "commercial break".to_string(),
            "sponsor message".to_string(),
            "ad segment".to_string(),
            "advertisement".to_string(),
            "advertisements".to_string(),
        ];

        let exit_phrases = vec![
            "welcome back".to_string(),
            "back to the show".to_string(),
            "back to the episode".to_string(),
            "back to our conversation".to_string(),
            "back to the podcast".to_string(),
            "back to it could happen here".to_string(),
            "now let's get back".to_string(),
            "now lets get back".to_string(),
            "and now back to".to_string(),
            "and we're back".to_string(),
            "and were back".to_string(),
            "we're back".to_string(),
            "were back".to_string(),
            "we are back".to_string(),
            "let's dive back in".to_string(),
            "thanks again to our sponsor".to_string(),
            "that's code".to_string(),
            "thats code".to_string(),
            "welcome back to".to_string(),
            "and we are back".to_string(),
            "let's get back to".to_string(),
            "lets get back to".to_string(),
            "let's get back".to_string(),
            "lets get back".to_string(),
            "back with".to_string(),
            "lets dive back in".to_string(),
        ];

        let trigger_matcher = AhoCorasickBuilder::new()
            .ascii_case_insensitive(true)
            .match_kind(MatchKind::LeftmostLongest)
            .build(&trigger_phrases)
            .expect("Failed to build trigger AhoCorasick");

        let exit_matcher = AhoCorasickBuilder::new()
            .ascii_case_insensitive(true)
            .match_kind(MatchKind::LeftmostLongest)
            .build(&exit_phrases)
            .expect("Failed to build exit AhoCorasick");

        let chapter_ad_regex = Regex::new(
            r"(?i)\b(sponsor|sponsors|sponsored|advertisement|ad break|promo|commercial|promotions?)\b"
        ).expect("Failed to compile chapter ad regex");

        Self {
            trigger_matcher,
            exit_matcher,
            trigger_phrases,
            exit_phrases,
            chapter_ad_regex,
            stream_tokens: VecDeque::new(),
            max_stream_window_secs: 480.0, // Default 8 min lookback window
            current_ad_start: None,
        }
    }

    /// Check if a chapter title represents an ad/sponsor segment
    pub fn is_ad_chapter(&self, title: &str) -> bool {
        self.chapter_ad_regex.is_match(title)
    }

    /// Detect ad segments in a list of chapters
    pub fn detect_chapter_ads(&self, chapters: &[Chapter]) -> Vec<AdSegment> {
        let mut segments = Vec::new();
        for chapter in chapters {
            if self.is_ad_chapter(&chapter.title) {
                segments.push(AdSegment {
                    start_time: chapter.start_time,
                    end_time: chapter.end_time,
                    confidence: 0.95,
                    reason: format!("Chapter: {}", chapter.title),
                });
            }
        }
        segments
    }

    /// Parse WebVTT transcript and detect ad segments
    pub fn parse_and_detect_vtt(&self, vtt: &str) -> Vec<AdSegment> {
        let cues = parse_vtt_cues(vtt);
        self.detect_ads_in_cues(&cues)
    }

    /// Parse SRT transcript and detect ad segments
    pub fn parse_and_detect_srt(&self, srt: &str) -> Vec<AdSegment> {
        let cues = parse_srt_cues(srt);
        self.detect_ads_in_cues(&cues)
    }

    /// Detect ad segments across timed text cues
    pub fn detect_ads_in_cues(&self, cues: &[TranscriptCue]) -> Vec<AdSegment> {
        let mut segments = Vec::new();
        if cues.is_empty() {
            return segments;
        }

        let mut in_ad = false;
        let mut ad_start = 0.0;
        let mut trigger_reason = String::new();
        let default_ad_duration: f64 = 60.0; // fallback if no exit phrase found

        for (i, cue) in cues.iter().enumerate() {
            let text = &cue.text;

            if !in_ad {
                if let Some(m) = self.trigger_matcher.find(text) {
                    let phrase = &self.trigger_phrases[m.pattern()];
                    in_ad = true;
                    ad_start = cue.start_time;
                    trigger_reason = format!("Trigger: {}", phrase);
                }
            } else {
                // Look for exit cue
                let is_exit = self.exit_matcher.is_match(text);
                let time_elapsed = cue.end_time - ad_start;

                if is_exit || time_elapsed >= self.max_stream_window_secs {
                    let end_time = if is_exit {
                        cue.end_time
                    } else {
                        ad_start + default_ad_duration.min(time_elapsed)
                    };

                    segments.push(AdSegment {
                        start_time: ad_start,
                        end_time,
                        confidence: if is_exit { 0.9 } else { 0.7 },
                        reason: trigger_reason.clone(),
                    });
                    in_ad = false;
                } else if i == cues.len() - 1 {
                    // Reached end while still in ad
                    segments.push(AdSegment {
                        start_time: ad_start,
                        end_time: cue.end_time,
                        confidence: 0.75,
                        reason: trigger_reason.clone(),
                    });
                    in_ad = false;
                }
            }
        }

        segments
    }

    /// Feed a live word token (e.g. from speech-to-text recognition).
    /// Returns an AdSegment if an ad boundary or event was confirmed!
    pub fn feed_word(&mut self, word: &str, start_time: f64, end_time: f64) -> Option<AdSegment> {
        let trimmed = word.trim().to_lowercase();
        if trimmed.is_empty() {
            return None;
        }

        self.stream_tokens.push_back(TimedWord {
            word: trimmed,
            start_time,
            end_time,
        });

        // Prune old tokens beyond max window
        while let Some(front) = self.stream_tokens.front() {
            if end_time - front.start_time > self.max_stream_window_secs {
                self.stream_tokens.pop_front();
            } else {
                break;
            }
        }

        // Build recent window text (last 20 words or 30 seconds)
        let recent_words: Vec<&str> = self
            .stream_tokens
            .iter()
            .rev()
            .take(25)
            .map(|t| t.word.as_str())
            .collect();
        let mut forward_words = recent_words;
        forward_words.reverse();
        let window_text = forward_words.join(" ");

        if let Some(ad_start) = self.current_ad_start {
            // Check for exit phrase in recent tokens
            if let Some(m) = self.exit_matcher.find(&window_text) {
                let _exit_phrase = &self.exit_phrases[m.pattern()];
                let segment = AdSegment {
                    start_time: ad_start,
                    end_time,
                    confidence: 0.88,
                    reason: "Live ad exit detected".to_string(),
                };
                self.current_ad_start = None;
                return Some(segment);
            }

            // Auto-timeout after 8 minutes of ad
            if end_time - ad_start > 480.0 {
                let segment = AdSegment {
                    start_time: ad_start,
                    end_time,
                    confidence: 0.70,
                    reason: "Live ad timeout (max duration reached)".to_string(),
                };
                self.current_ad_start = None;
                return Some(segment);
            }
        } else {
            // Check for trigger phrase in recent tokens
            if let Some(m) = self.trigger_matcher.find(&window_text) {
                let phrase = &self.trigger_phrases[m.pattern()];
                // Ad started at the earliest token in this matching window
                let match_start = self
                    .stream_tokens
                    .iter()
                    .rev()
                    .take(25)
                    .last()
                    .map(|t| t.start_time)
                    .unwrap_or(start_time);

                self.current_ad_start = Some(match_start);
                return Some(AdSegment {
                    start_time: match_start,
                    end_time: match_start + 180.0, // initial estimated duration (3 min)
                    confidence: 0.85,
                    reason: format!("Live ad trigger: {}", phrase),
                });
            }
        }

        None
    }

    pub fn reset_stream(&mut self) {
        self.stream_tokens.clear();
        self.current_ad_start = None;
    }
}

#[derive(Debug, Clone)]
pub struct TranscriptCue {
    pub start_time: f64,
    pub end_time: f64,
    pub text: String,
}

fn parse_timestamp(s: &str) -> Option<f64> {
    let s = s.trim();
    let parts: Vec<&str> = s.split(':').collect();
    match parts.len() {
        2 => {
            let mins: f64 = parts[0].parse().ok()?;
            let secs: f64 = parts[1].replace(',', ".").parse().ok()?;
            Some(mins * 60.0 + secs)
        }
        3 => {
            let hours: f64 = parts[0].parse().ok()?;
            let mins: f64 = parts[1].parse().ok()?;
            let secs: f64 = parts[2].replace(',', ".").parse().ok()?;
            Some(hours * 3600.0 + mins * 60.0 + secs)
        }
        _ => None,
    }
}

pub fn parse_vtt_cues(vtt: &str) -> Vec<TranscriptCue> {
    let mut cues = Vec::new();
    let lines: Vec<&str> = vtt.lines().collect();
    let mut i = 0;

    while i < lines.len() {
        let line = lines[i].trim();
        if line.contains("-->") {
            let parts: Vec<&str> = line.split("-->").collect();
            if parts.len() == 2 {
                let start = parse_timestamp(parts[0].split_whitespace().next().unwrap_or(""));
                let end = parse_timestamp(parts[1].split_whitespace().next().unwrap_or(""));

                if let (Some(start_time), Some(end_time)) = (start, end) {
                    let mut text_lines = Vec::new();
                    i += 1;
                    while i < lines.len() && !lines[i].trim().is_empty() {
                        text_lines.push(lines[i].trim());
                        i += 1;
                    }
                    cues.push(TranscriptCue {
                        start_time,
                        end_time,
                        text: text_lines.join(" "),
                    });
                    continue;
                }
            }
        }
        i += 1;
    }
    cues
}

pub fn parse_srt_cues(srt: &str) -> Vec<TranscriptCue> {
    let mut cues = Vec::new();
    let blocks = srt.split("\n\n");

    for block in blocks {
        let lines: Vec<&str> = block.lines().map(|l| l.trim()).filter(|l| !l.is_empty()).collect();
        if lines.len() >= 2 {
            let time_line = if lines[0].contains("-->") {
                lines[0]
            } else if lines[1].contains("-->") {
                lines[1]
            } else {
                continue;
            };

            let parts: Vec<&str> = time_line.split("-->").collect();
            if parts.len() == 2 {
                let start = parse_timestamp(parts[0]);
                let end = parse_timestamp(parts[1]);

                if let (Some(start_time), Some(end_time)) = (start, end) {
                    let text_start_idx = if lines[0].contains("-->") { 1 } else { 2 };
                    let text = lines[text_start_idx..].join(" ");
                    cues.push(TranscriptCue {
                        start_time,
                        end_time,
                        text,
                    });
                }
            }
        }
    }
    cues
}
