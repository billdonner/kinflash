import Foundation
import PDFKit
import UIKit

struct PDFExporter {
    /// Card size: 4x6 inches at 72 DPI
    private let cardWidth: CGFloat = 4 * 72   // 288 points
    private let cardHeight: CGFloat = 6 * 72  // 432 points
    private let margin: CGFloat = 36          // 0.5 inch

    func exportDeck(deckName: String, cards: [(question: String, answer: String, explanation: String?)]) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: cardWidth, height: cardHeight))

        let data = renderer.pdfData { context in
            for (index, card) in cards.enumerated() {
                // Front page (question)
                context.beginPage()
                drawFront(
                    context: context.cgContext,
                    question: card.question,
                    deckName: deckName,
                    cardNumber: index + 1,
                    totalCards: cards.count
                )

                // Back page (answer)
                context.beginPage()
                drawBack(
                    context: context.cgContext,
                    answer: card.answer,
                    explanation: card.explanation,
                    deckName: deckName
                )
            }
        }

        return data
    }

    private func drawFront(context: CGContext, question: String, deckName: String, cardNumber: Int, totalCards: Int) {
        let textRect = CGRect(
            x: margin,
            y: margin + 40,
            width: cardWidth - margin * 2,
            height: cardHeight - margin * 2 - 80
        )

        let questionStyle = NSMutableParagraphStyle()
        questionStyle.alignment = .center

        let questionAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 20, weight: .medium),
            .foregroundColor: UIColor.black,
            .paragraphStyle: questionStyle
        ]

        let questionStr = NSAttributedString(string: question, attributes: questionAttrs)
        questionStr.draw(in: textRect)

        // Footer
        let footerRect = CGRect(
            x: margin,
            y: cardHeight - margin - 20,
            width: cardWidth - margin * 2,
            height: 20
        )
        let footerStyle = NSMutableParagraphStyle()
        footerStyle.alignment = .center

        let footerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: UIColor.gray,
            .paragraphStyle: footerStyle
        ]

        let footerStr = NSAttributedString(string: "\(deckName) — Card \(cardNumber) of \(totalCards)", attributes: footerAttrs)
        footerStr.draw(in: footerRect)
    }

    private func drawBack(context: CGContext, answer: String, explanation: String?, deckName: String) {
        // Header
        let headerRect = CGRect(x: margin, y: margin, width: cardWidth - margin * 2, height: 20)
        let headerStyle = NSMutableParagraphStyle()
        headerStyle.alignment = .center
        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: UIColor.gray,
            .paragraphStyle: headerStyle
        ]
        NSAttributedString(string: deckName, attributes: headerAttrs).draw(in: headerRect)

        // Answer
        let answerRect = CGRect(
            x: margin,
            y: margin + 60,
            width: cardWidth - margin * 2,
            height: 100
        )
        let answerStyle = NSMutableParagraphStyle()
        answerStyle.alignment = .center
        let answerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24, weight: .bold),
            .foregroundColor: UIColor.black,
            .paragraphStyle: answerStyle
        ]
        NSAttributedString(string: answer, attributes: answerAttrs).draw(in: answerRect)

        // Explanation
        if let explanation = explanation {
            let explRect = CGRect(
                x: margin,
                y: margin + 180,
                width: cardWidth - margin * 2,
                height: cardHeight - margin * 2 - 200
            )
            let explStyle = NSMutableParagraphStyle()
            explStyle.alignment = .center
            let explAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: UIColor.darkGray,
                .paragraphStyle: explStyle
            ]
            NSAttributedString(string: explanation, attributes: explAttrs).draw(in: explRect)
        }
    }
}
