import boto3
import os
import re
from fpdf import FPDF, FPDFException

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
course_metadata = dynamodb.Table(os.environ["COURSE_METADATA_TABLE"])

PROCESSED_BUCKET = os.environ["PROCESSED_BUCKET"]

# Symbols the core PDF fonts cannot draw, written out as plain text so
# they do not turn into "?". Characters Windows-1252 already has (such as
# x, degree, plus-minus, superscript 2 and 3) are not listed.
SYMBOL_MAP = {
    # arrows
    "→": "->", "←": "<-", "↔": "<->", "⇒": "=>", "⇐": "<=", "⇔": "<=>",
    "↑": "(up)", "↓": "(down)",
    # maths
    "−": "-", "‐": "-", "‑": "-", "≈": "~", "≠": "!=", "≤": "<=", "≥": ">=",
    "≪": "<<", "≫": ">>", "≡": "==", "≅": "~=", "∞": "infinity", "√": "sqrt",
    "∑": "sum", "∏": "product", "∫": "integral", "∂": "d", "∇": "nabla",
    "∝": "proportional to", "∈": "in", "∴": "therefore", "∵": "because",
    "∀": "for all", "∃": "there exists", "∅": "empty set", "⊥": "perpendicular to",
    "∥": "||", "∠": "angle", "⋅": "·", "∙": "·", "′": "'", "″": '"',
    "ħ": "hbar", "ℏ": "hbar", "℃": "°C",
    # superscripts and subscripts
    "⁰": "^0", "⁴": "^4", "⁵": "^5", "⁶": "^6", "⁷": "^7", "⁸": "^8", "⁹": "^9",
    "⁺": "^+", "⁻": "^-", "ⁿ": "^n",
    "₀": "_0", "₁": "_1", "₂": "_2", "₃": "_3", "₄": "_4",
    "₅": "_5", "₆": "_6", "₇": "_7", "₈": "_8", "₉": "_9",
    # Greek letters (lowercase)
    "α": "alpha", "β": "beta", "γ": "gamma", "δ": "delta", "ε": "epsilon",
    "ζ": "zeta", "η": "eta", "θ": "theta", "ι": "iota", "κ": "kappa",
    "λ": "lambda", "μ": "mu", "ν": "nu", "ξ": "xi", "ο": "omicron",
    "π": "pi", "ρ": "rho", "σ": "sigma", "ς": "sigma", "τ": "tau",
    "υ": "upsilon", "φ": "phi", "χ": "chi", "ψ": "psi", "ω": "omega",
    # Greek letters (uppercase)
    "Γ": "Gamma", "Δ": "Delta", "∆": "Delta", "Θ": "Theta", "Λ": "Lambda",
    "Ξ": "Xi", "Π": "Pi", "Σ": "Sigma", "Φ": "Phi", "Ψ": "Psi", "Ω": "Omega",
}
SYMBOL_TABLE = str.maketrans(SYMBOL_MAP)

def sanitize(text):
    # Core PDF fonts only support Windows-1252 (256 characters). Known
    # symbols are first written out as text (see SYMBOL_MAP). Anything
    # still outside Windows-1252 (emoji, other scripts) is replaced
    # rather than crashing the whole render.
    text = text.translate(SYMBOL_TABLE)
    return text.encode("cp1252", "replace").decode("cp1252")

def strip_inline_markdown(text):
    # Bedrock's Markdown formatting instruction can produce inline
    # **bold** / *italic* / `code` markers even in body text, not just
    # headers - strip the markers, keep the inner text.
    text = re.sub(r"\*\*(.*?)\*\*", r"\1", text)
    text = re.sub(r"(?<!\*)\*(?=\S)(.+?)(?<=\S)\*(?!\*)", r"\1", text)
    text = re.sub(r"`(.*?)`", r"\1", text)
    return text

def render_line(pdf, text, size, height, bold=False):
    # Explicitly reset the cursor to the left margin before every call,
    # rather than trusting fpdf2 to always do this automatically - this
    # is the actual root cause of the "not enough horizontal space"
    # error (cursor drift near the page edge, unrelated to the text
    # content itself).
    pdf.set_x(pdf.l_margin)
    pdf.set_font("Helvetica", "B" if bold else "", size)
    try:
        pdf.multi_cell(0, height, text)
    except FPDFException:
        # Defensive fallback: never let one problematic line take down
        # the entire PDF (and therefore the whole pipeline execution).
        # Skip it and keep going rather than failing the whole render.
        print(f"Skipped one unrenderable line: {text!r}")

def handler(event, context):
    notes_text = event["studyNotesResult"]["notes"]
    job_name = event["transcribeResult"]["TranscriptionJobName"]

    pdf = FPDF()
    pdf.add_page()
    pdf.set_auto_page_break(auto=True, margin=15)

    for raw_line in notes_text.split("\n"):
        line = sanitize(raw_line.strip())

        if not line:
            pdf.ln(4)
        elif line.startswith("### "):
            render_line(pdf, strip_inline_markdown(line[4:]), 13, 8, bold=True)
        elif line.startswith("## "):
            render_line(pdf, strip_inline_markdown(line[3:]), 15, 9, bold=True)
        elif line.startswith("# "):
            render_line(pdf, strip_inline_markdown(line[2:]), 18, 10, bold=True)
        elif line.startswith("- ") or line.startswith("* "):
            render_line(pdf, f"    -  {strip_inline_markdown(line[2:])}", 11, 7)
        else:
            render_line(pdf, strip_inline_markdown(line), 11, 7)

    output_path = "/tmp/study_notes.pdf"
    pdf.output(output_path)

    pdf_key = f"study-notes/{job_name}.pdf"
    s3.upload_file(output_path, PROCESSED_BUCKET, pdf_key)

    video_id = event.get("video_id")
    if video_id:
        course_metadata.update_item(
            Key={"video_id": video_id},
            UpdateExpression="SET pdf_key = :pdf_key, #s = :status",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={":pdf_key": pdf_key, ":status": "COMPLETE"}
        )

    return {"pdf_key": pdf_key}