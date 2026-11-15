import Testing
@testable import ProjectN

struct DictionaryMatcherTests {
    let terms = ["Nvoice", "keywords", "SEO", "Monterrey", "Saltillo", "codex", "4vmarketing", "Search Console"]

    func fix(_ s: String) -> String { DictionaryMatcher.apply(terms: terms, to: s) }

    @Test func testSoundAlikeSpansBecomeTheTerm() {
        #expect(fix("Utiliza el MCP de elemento para 4B marketing") == "Utiliza el MCP de elemento para 4vmarketing")
        #expect(fix("post it on for v marketing today") == "post it on 4vmarketing today")
        #expect(fix("Four B. Marketing is the agency") == "4vmarketing is the agency")
        #expect(fix("this is a code x conversation") == "this is a codex conversation")
        #expect(fix("I want the S E O core app") == "I want the SEO core app")
        #expect(fix("vamos a saltiyo y monterey") == "vamos a Saltillo y Monterrey")
        #expect(fix("find the key words for it") == "find the keywords for it")
        #expect(fix("open search console now") == "open Search Console now")
        #expect(fix("errores con N voice") == "errores con Nvoice")
    }

    @Test func testLeavesOrdinarySpeechAlone() {
        #expect(fix("Send the invoice to the CEO") == "Send the invoice to the CEO")
        #expect(fix("I bought a new keyboard") == "I bought a new keyboard")
        #expect(fix("go to seo.com and email me@codex.io") == "go to seo.com and email me@codex.io")
        #expect(fix("for the marketing team") == "for the marketing team")
        #expect(fix("Already 4vmarketing and Saltillo.") == "Already 4vmarketing and Saltillo.")
    }

    @Test func testCapitalizationAndPunctuationKept() {
        #expect(fix("seo, then monterrey.") == "SEO, then Monterrey.")
    }
}
