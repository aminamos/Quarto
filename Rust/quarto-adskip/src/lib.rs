pub mod engine;
pub mod ffi;

pub use engine::*;
pub use ffi::*;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_chapter_ad_detection() {
        let engine = AdSkipEngine::new();
        assert!(engine.is_ad_chapter("Sponsor: Squarespace"));
        assert!(engine.is_ad_chapter("Midroll Ad Break"));
        assert!(engine.is_ad_chapter("Commercial Break"));
        assert!(engine.is_ad_chapter("Special Promo"));
        assert!(!engine.is_ad_chapter("Chapter 1: Introduction to Quarto"));
        assert!(!engine.is_ad_chapter("Interview with Amin"));

        let chapters = vec![
            Chapter {
                title: "Introduction".into(),
                start_time: 0.0,
                end_time: 120.0,
            },
            Chapter {
                title: "Sponsor - Audible".into(),
                start_time: 120.0,
                end_time: 180.0,
            },
            Chapter {
                title: "Main Topic".into(),
                start_time: 180.0,
                end_time: 600.0,
            },
        ];

        let ads = engine.detect_chapter_ads(&chapters);
        assert_eq!(ads.len(), 1);
        assert_eq!(ads[0].start_time, 120.0);
        assert_eq!(ads[0].end_time, 180.0);
    }

    #[test]
    fn test_vtt_ad_detection() {
        let engine = AdSkipEngine::new();
        let vtt = r#"WEBVTT

00:00:01.000 --> 00:00:05.000
Welcome to the podcast everyone.

00:00:05.500 --> 00:00:12.000
Today's episode is sponsored by Quarto, the best player for iOS.

00:00:12.500 --> 00:00:20.000
Use code AMOS for 20% off your subscription.

00:00:20.500 --> 00:00:25.000
Now welcome back to the show, let's get into the news.
"#;

        let ads = engine.parse_and_detect_vtt(vtt);
        assert_eq!(ads.len(), 1);
        assert_eq!(ads[0].start_time, 5.5);
        assert_eq!(ads[0].end_time, 25.0);
    }

    #[test]
    fn test_streaming_word_tokens() {
        let mut engine = AdSkipEngine::new();

        assert!(engine.feed_word("hello", 0.0, 0.5).is_none());
        assert!(engine.feed_word("and", 0.5, 0.8).is_none());

        // Feed trigger phrase
        let ad_trigger = engine.feed_word("sponsored", 10.0, 10.5);
        assert!(ad_trigger.is_none());
        let ad_trigger = engine.feed_word("by", 10.6, 11.0);
        assert!(ad_trigger.is_some());
        let seg = ad_trigger.unwrap();
        assert!(seg.start_time <= 10.6);

        // Feed filler
        assert!(engine.feed_word("acme", 11.5, 12.0).is_none());
        assert!(engine.feed_word("corp", 12.1, 12.5).is_none());

        // Feed exit phrase
        let ad_exit = engine.feed_word("welcome", 30.0, 30.4);
        assert!(ad_exit.is_none());
        let ad_exit = engine.feed_word("back", 30.5, 31.0);
        assert!(ad_exit.is_some());
        let exit_seg = ad_exit.unwrap();
        assert_eq!(exit_seg.end_time, 31.0);
    }
}
