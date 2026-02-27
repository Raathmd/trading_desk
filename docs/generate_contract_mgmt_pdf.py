#!/usr/bin/env python3
"""Generate Contract Management Process Flow PDF document."""

from fpdf import FPDF
from fpdf.enums import XPos, YPos

# -- Colors --
NAVY = (11, 29, 58)
BLUE = (26, 58, 107)
ACCENT = (46, 134, 222)
GOLD = (230, 168, 23)
GREEN = (39, 174, 96)
RED = (231, 76, 60)
ORANGE = (243, 156, 18)
PURPLE = (142, 68, 173)
WHITE = (255, 255, 255)
LIGHT = (240, 244, 248)
DARK_TEXT = (44, 62, 80)
GREY = (107, 124, 141)
LIGHT_BLUE = (235, 245, 251)
LIGHT_GREEN = (234, 250, 241)


class ContractPDF(FPDF):
    def __init__(self):
        super().__init__('L', 'mm', 'A4')  # Landscape
        self.set_auto_page_break(auto=True, margin=15)

    def header_bar(self):
        """Draw the navy header bar."""
        self.set_fill_color(*NAVY)
        self.rect(0, 0, 297, 22, 'F')
        self.set_text_color(*WHITE)
        self.set_font('Helvetica', 'B', 9)
        self.set_xy(10, 7)
        self.cell(0, 8, 'Trammo Trading Desk  |  Contract Management Process Flows  |  February 2026  |  Confidential', align='L')

    def footer(self):
        self.set_y(-12)
        self.set_font('Helvetica', '', 7)
        self.set_text_color(*GREY)
        self.cell(0, 10, f'Page {self.page_no()}', align='C')

    def section_title(self, num, title):
        self.set_font('Helvetica', 'B', 18)
        self.set_text_color(*ACCENT)
        self.cell(10, 10, str(num), align='C')
        self.set_text_color(*NAVY)
        self.cell(0, 10, f'  {title}', new_x=XPos.LMARGIN, new_y=YPos.NEXT)
        self.ln(2)

    def lead_text(self, text):
        self.set_font('Helvetica', '', 11)
        self.set_text_color(*GREY)
        self.multi_cell(0, 6, text)
        self.ln(4)

    def body_text(self, text):
        self.set_font('Helvetica', '', 10)
        self.set_text_color(*DARK_TEXT)
        self.multi_cell(0, 5, text)
        self.ln(2)

    def callout_box(self, text, color=ACCENT):
        x, y = self.get_x(), self.get_y()
        self.set_fill_color(color[0], color[1], color[2])
        self.rect(x, y, 3, 14, 'F')
        bg = LIGHT_BLUE if color == ACCENT else LIGHT_GREEN if color == GREEN else (254, 249, 231)
        self.set_fill_color(*bg)
        self.rect(x + 3, y, 270, 14, 'F')
        self.set_xy(x + 7, y + 2)
        self.set_font('Helvetica', '', 9)
        self.set_text_color(*DARK_TEXT)
        self.multi_cell(263, 5, text)
        self.set_y(y + 17)

    def table_header(self, cols, widths):
        self.set_fill_color(*NAVY)
        self.set_text_color(*WHITE)
        self.set_font('Helvetica', 'B', 9)
        for i, (col, w) in enumerate(zip(cols, widths)):
            self.cell(w, 8, col, border=0, fill=True, align='L')
        self.ln()

    def table_row(self, cells, widths, bold_first=True, alt=False):
        bg = LIGHT_BLUE if alt else WHITE
        self.set_fill_color(*bg)
        self.set_text_color(*DARK_TEXT)
        for i, (cell, w) in enumerate(zip(cells, widths)):
            if i == 0 and bold_first:
                self.set_font('Helvetica', 'B', 9)
            else:
                self.set_font('Helvetica', '', 9)
            self.cell(w, 7, cell, border=0, fill=True, align='L')
        self.ln()


pdf = ContractPDF()

# Page 1: Title
pdf.add_page()
pdf.set_fill_color(*NAVY)
pdf.rect(0, 0, 297, 210, 'F')

pdf.set_text_color(*WHITE)
pdf.set_font('Helvetica', 'B', 36)
pdf.set_y(55)
pdf.cell(0, 20, 'Contract Management', align='C', new_x=XPos.LMARGIN, new_y=YPos.NEXT)
pdf.cell(0, 20, 'Process Flows', align='C', new_x=XPos.LMARGIN, new_y=YPos.NEXT)

pdf.set_font('Helvetica', '', 16)
pdf.set_text_color(160, 174, 192)
pdf.ln(8)
pdf.cell(0, 10, 'Trammo Trading Desk', align='C', new_x=XPos.LMARGIN, new_y=YPos.NEXT)
pdf.cell(0, 10, '7-Step Contract Wizard & Solver Integration', align='C', new_x=XPos.LMARGIN, new_y=YPos.NEXT)

pdf.ln(15)
pdf.set_font('Helvetica', '', 11)
pdf.set_text_color(*GREY)
pdf.cell(0, 8, 'February 2026  |  Confidential', align='C')


# Page 2: Overview
pdf.add_page()
pdf.header_bar()
pdf.set_y(28)
pdf.section_title(1, 'Contract Management Overview')
pdf.lead_text(
    'The Contract Management module is a guided 7-step wizard that takes traders from product group '
    'selection through counterparty identification, commercial negotiation, clause selection, LP solver '
    'validation, review, and final approval -- all within a single real-time LiveView interface.'
)

# Step boxes
steps = [
    ('1', 'Product Group', 'Select product group'),
    ('2', 'Counterparty', 'Name, commodity, dates'),
    ('3', 'Commercial', 'Qty, price, freight'),
    ('4', 'Clauses', 'Select clauses'),
    ('5', 'Optimizer', 'HiGHS + Claude AI'),
    ('6', 'Review', 'Full summary'),
    ('7', 'Approval', 'Submit & create'),
]
x_start = 12
box_w = 37
for i, (num, title, desc) in enumerate(steps):
    x = x_start + i * (box_w + 2)
    color = GREEN if num in ('5', '7') else ACCENT
    pdf.set_fill_color(*LIGHT_BLUE)
    pdf.set_draw_color(*color)
    pdf.rect(x, 58, box_w, 24, 'DF')
    # Number circle
    pdf.set_fill_color(*color)
    pdf.ellipse(x + 2, 59, 8, 8, 'F')
    pdf.set_text_color(*WHITE)
    pdf.set_font('Helvetica', 'B', 9)
    pdf.set_xy(x + 2, 59.5)
    pdf.cell(8, 7, num, align='C')
    # Title
    pdf.set_text_color(*NAVY)
    pdf.set_font('Helvetica', 'B', 9)
    pdf.set_xy(x + 11, 59)
    pdf.cell(box_w - 13, 6, title)
    # Desc
    pdf.set_text_color(*GREY)
    pdf.set_font('Helvetica', '', 8)
    pdf.set_xy(x + 3, 68)
    pdf.cell(box_w - 6, 5, desc)

pdf.set_y(88)
pdf.callout_box(
    'KEY DIFFERENTIATOR: Unlike traditional contract management systems, Trammo integrates an LP solver directly '
    'into Step 5 -- giving traders quantitative validation of contract economics BEFORE approval.',
    GREEN
)

# Wizard state diagram description
pdf.ln(4)
pdf.set_font('Helvetica', 'B', 13)
pdf.set_text_color(*NAVY)
pdf.cell(0, 8, 'Wizard State Machine', new_x=XPos.LMARGIN, new_y=YPos.NEXT)
pdf.ln(2)
pdf.body_text(
    'Step 1 -> Step 2: Validate product group selected\n'
    'Step 2 -> Step 3: Validate counterparty name, commodity, delivery dates\n'
    'Step 3 -> Step 4: Validate quantity and price are set\n'
    'Step 4 -> Step 5: Validate at least 1 clause selected\n'
    'Step 5 -> Step 6: Always valid (solver is optional but recommended)\n'
    'Step 6 -> Step 7: Always valid (review is informational)\n'
    'Step 7: Submit for Approval -> DB Transaction\n\n'
    'Back navigation is always available from any step > 1.'
)


# Page 3: Steps 1-3
pdf.add_page()
pdf.header_bar()
pdf.set_y(28)
pdf.section_title(2, 'Steps 1-3: Product Group, Counterparty, Commercial Terms')

# Step 1
pdf.set_font('Helvetica', 'B', 12)
pdf.set_text_color(*ACCENT)
pdf.cell(0, 8, 'Step 1: Product Group Selection', new_x=XPos.LMARGIN, new_y=YPos.NEXT)
pdf.body_text(
    'Four product groups available:\n'
    '  * NH3 Domestic Barge (AD) -- Anhydrous Ammonia, Aqua Ammonia\n'
    '  * Sulphur International (SI) -- Granular, Liquid, Formed\n'
    '  * Petcoke (PC) -- Fuel-Grade, Anode-Grade, Calcined\n'
    '  * NH3 International (AI) -- Anhydrous Ammonia, Ammonia Solution\n'
    'Validation: Must select one product group to proceed.'
)

# Step 2
pdf.set_font('Helvetica', 'B', 12)
pdf.set_text_color(*ACCENT)
pdf.cell(0, 8, 'Step 2: Counterparty & Commodity', new_x=XPos.LMARGIN, new_y=YPos.NEXT)

widths = [55, 40, 65, 60]
pdf.table_header(['Field', 'Type', 'Validation', 'Example'], widths)
rows = [
    ['Counterparty Name', 'Text input', 'Required, non-empty', 'ACME Trading Corp'],
    ['Commodity', 'Select (filtered)', 'Required, matches product group', 'Anhydrous Ammonia'],
    ['Delivery Window Start', 'Date picker', 'Required', '2026-03-15'],
    ['Delivery Window End', 'Date picker', 'Required', '2026-04-30'],
]
for i, row in enumerate(rows):
    pdf.table_row(row, widths, alt=i % 2 == 0)
pdf.ln(4)

# Step 3
pdf.set_font('Helvetica', 'B', 12)
pdf.set_text_color(*ACCENT)
pdf.cell(0, 8, 'Step 3: Commercial Terms', new_x=XPos.LMARGIN, new_y=YPos.NEXT)

widths = [50, 50, 50, 70]
pdf.table_header(['Field', 'Type', 'Validation', 'Solver Mapping'], widths)
rows = [
    ['Quantity + Unit', 'Number (MT/KT/BBL)', 'Required', '--'],
    ['Proposed Price (USD)', 'Number (2 dec)', 'Required', 'nh3_price override'],
    ['Proposed Freight', 'Number (2 dec)', 'Optional', 'barge_freight override'],
    ['Payment Terms', 'Select', 'Default: Net 30', '--'],
    ['Incoterm', 'Select', 'Default: FOB', '--'],
]
for i, row in enumerate(rows):
    pdf.table_row(row, widths, alt=i % 2 == 0)
pdf.ln(2)
pdf.callout_box(
    'SOLVER INTEGRATION: Proposed price maps to nh3_price and proposed freight maps to barge_freight in the solver '
    'variable space. These overrides are applied on top of the product group defaults when the optimizer runs in Step 5.',
    ACCENT
)


# Page 4: Steps 4-5
pdf.add_page()
pdf.header_bar()
pdf.set_y(28)
pdf.section_title(3, 'Steps 4-5: Clause Selection & Optimizer Validation')

# Step 4
pdf.set_font('Helvetica', 'B', 12)
pdf.set_text_color(*ACCENT)
pdf.cell(0, 8, 'Step 4: Clause Selection', new_x=XPos.LMARGIN, new_y=YPos.NEXT)

widths = [55, 40, 125]
pdf.table_header(['Clause', 'Default', 'Description'], widths)
clauses = [
    ['Force Majeure', 'Pre-selected', 'Acts of God, war, government actions'],
    ['Demurrage & Dispatch', '--', 'Vessel/barge demurrage rates and dispatch rebate terms'],
    ['Quality Specification', '--', 'Product quality requirements, testing methods, rejection criteria'],
    ['Quantity Tolerance', '--', '+/- 5% at seller\'s option'],
    ['Price Escalation', '--', 'Index-linked price adjustment mechanism'],
    ['Payment Terms', 'Pre-selected', 'Net 30 days from bill of lading date'],
    ['Insurance & Liability', '--', 'Marine cargo insurance requirements and liability limits'],
    ['Dispute Resolution', '--', 'Arbitration -- LCIA London or ICC Paris'],
    ['Termination Rights', '--', 'Early termination triggers and notice requirements'],
    ['Confidentiality', '--', 'Non-disclosure of contract terms and pricing'],
]
for i, row in enumerate(clauses):
    pdf.table_row(row, widths, alt=i % 2 == 0)
pdf.ln(4)

# Step 5
pdf.set_font('Helvetica', 'B', 12)
pdf.set_text_color(*GREEN)
pdf.cell(0, 8, 'Step 5: Optimizer Validation (Key Differentiator)', new_x=XPos.LMARGIN, new_y=YPos.NEXT)
pdf.body_text(
    'When the trader clicks "Run Optimizer Validation":\n\n'
    '1. Load product group default variables (20 vars from live state)\n'
    '2. Apply contract overrides: proposed_price -> nh3_price, proposed_freight -> barge_freight\n'
    '3. Execute Solver.solve(product_group, vars) via Zig/HiGHS linear program\n'
    '4. Display results: Status | Profit | Tons | ROI (4-card grid)\n'
    '5. Show route allocations (Route 1, Route 2, ...)\n'
    '6. Run PostsolveExplainer.explain_all() -- Claude AI generates 3-5 sentence explanation\n\n'
    'Outcomes: OPTIMAL (viable), INFEASIBLE (needs adjustment), UNAVAILABLE (manual OK)\n'
    'The solver step is recommended but NOT required to proceed.'
)


# Page 5: Steps 6-7 & Data Model
pdf.add_page()
pdf.header_bar()
pdf.set_y(28)
pdf.section_title(4, 'Steps 6-7: Review & Approval')

# Step 6
pdf.set_font('Helvetica', 'B', 12)
pdf.set_text_color(*ACCENT)
pdf.cell(0, 8, 'Step 6: Review Summary', new_x=XPos.LMARGIN, new_y=YPos.NEXT)
pdf.body_text(
    'Consolidated view of all contract data: product group, counterparty, commodity, delivery dates, '
    'quantity, price, freight, payment terms, incoterm, selected clauses (as tags), and optimizer '
    'results (if run). No edits here -- navigate back to any step. Always valid to proceed.'
)

# Step 7
pdf.set_font('Helvetica', 'B', 12)
pdf.set_text_color(*GREEN)
pdf.cell(0, 8, 'Step 7: Approval Submission', new_x=XPos.LMARGIN, new_y=YPos.NEXT)
pdf.body_text(
    'Single Repo.transaction creates 5 records:\n\n'
    '1. CmContractNegotiation -- Full step_data, solver snapshot, trader ID\n'
    '2. CmContractNegotiationEvent -- type: submitted_for_approval, actor: trader email\n'
    '3. CmContract -- ref: CTR-{PREFIX}-{YYMMDDHHMM}-{hex}, status: pending_approval\n'
    '4. CmContractVersion (v1) -- Full terms snapshot\n'
    '5. CmContractApproval -- approver: trading_manager, status: pending\n\n'
    'Emits event: contract_submitted_for_approval -> EventEmitter -> VectorizationWorker -> pgvector'
)

# Data Model
pdf.ln(2)
pdf.set_font('Helvetica', 'B', 13)
pdf.set_text_color(*NAVY)
pdf.cell(0, 8, 'Data Model', new_x=XPos.LMARGIN, new_y=YPos.NEXT)
pdf.ln(1)

widths = [65, 155]
pdf.table_header(['Table', 'Key Columns'], widths)
model_rows = [
    ['cm_contract_negotiations', 'product_group, reference_number, counterparty, commodity, status, step_data, solver_snapshot, trader_id'],
    ['cm_contract_negotiation_events', 'event_type, step_number, actor, summary, details (jsonb)'],
    ['cm_contracts', 'contract_reference, counterparty, commodity, status, terms, selected_clause_ids, approved_by'],
    ['cm_contract_versions', 'version_number, terms_snapshot (jsonb), change_summary, created_by'],
    ['cm_contract_approvals', 'approver_id, approval_status, notes, decided_at'],
]
for i, row in enumerate(model_rows):
    pdf.table_row(row, widths, alt=i % 2 == 0)


# Page 6: Event Pipeline
pdf.add_page()
pdf.header_bar()
pdf.set_y(28)
pdf.section_title(5, 'Event Pipeline & Vectorization')
pdf.lead_text(
    'Every step transition emits events through the EventEmitter -> Oban -> pgvector pipeline, '
    'enabling semantic search over contract history.'
)

widths = [35, 80, 35, 70]
pdf.table_header(['Trigger', 'Event Type', 'Source', 'Key Payload'], widths)
events = [
    ['Step 1>2', 'contract_product_group_selected', 'contract_mgmt', 'product_group, user'],
    ['Step 2>3', 'contract_counterparty_set', 'contract_mgmt', 'counterparty, commodity'],
    ['Step 3>4', 'contract_commercial_terms_set', 'contract_mgmt', 'quantity, price, freight'],
    ['Step 4>5', 'contract_clauses_selected', 'contract_mgmt', 'selected clause count'],
    ['Step 5>6', 'contract_optimizer_complete', 'contract_mgmt', 'solver status, profit, ROI'],
    ['Step 6>7', 'contract_review_complete', 'contract_mgmt', 'review confirmation'],
    ['Optimizer', 'contract_optimizer_validated', 'contract_mgmt', 'full solver results'],
    ['Submit', 'contract_submitted_for_approval', 'contract_mgmt', 'negotiation_id, contract_id, all terms'],
]
for i, row in enumerate(events):
    pdf.table_row(row, widths, alt=i % 2 == 0)

pdf.ln(4)
pdf.body_text(
    'Pipeline: Contract Wizard -> EventEmitter.emit_event/3 -> event_log table -> '
    'Oban VectorizationWorker -> Embeddings.generate() -> pgvector vector_embeddings -> Semantic Search via VectorQuery'
)


# Page 7: Comparison vs sea.live
pdf.add_page()
pdf.header_bar()
pdf.set_y(28)
pdf.section_title(6, 'Competitive Positioning vs. sea.live')
pdf.lead_text(
    'sea.live provides contract management for commodity trading. Trammo adds quantitative '
    'solver validation and AI-powered decision support that transforms contracting from a '
    'legal/administrative function into a decision support tool.'
)

widths = [50, 60, 70, 40]
pdf.table_header(['Capability', 'sea.live', 'Trammo Trading Desk', 'Advantage'], widths)
comparisons = [
    ['Contract Workflow', 'Multi-step wizard', '7-step guided wizard', 'Comparable'],
    ['LP Solver Integration', 'Not available', 'HiGHS validates during contracting', 'Trammo'],
    ['AI-Powered Analysis', 'Not available', 'Claude explains solver output', 'Trammo'],
    ['Real-Time Data', 'Market data feeds', '20 live vars from 10+ APIs', 'Trammo'],
    ['Pre-Contract Optimize', 'Optimize after signing', 'Optimize BEFORE approval', 'Trammo'],
    ['Event Vectorization', 'Not available', 'pgvector semantic search', 'Trammo'],
    ['Counterparty Mgmt', 'Full KYC directory', 'Inline entry (extensible)', 'sea.live'],
    ['Solver Constraint', 'Contracts standalone', 'Approved = live constraint', 'Trammo'],
    ['Approval Workflow', 'Multi-level approvals', 'Role-based with audit trail', 'Comparable'],
]
for i, row in enumerate(comparisons):
    pdf.table_row(row, widths, alt=i % 2 == 0)

pdf.ln(4)
pdf.callout_box(
    'KEY INSIGHT: sea.live treats contract management as a legal/admin workflow -- contracts are created, reviewed, '
    'and approved without quantitative validation. Trammo inserts an LP solver BEFORE approval, giving traders '
    'projected profit, ROI, and route allocations computed against 20 live variables. Combined with Claude AI, '
    'this transforms contract approval from a compliance checkpoint into a DECISION SUPPORT MOMENT.',
    GREEN
)

pdf.ln(2)
pdf.callout_box(
    'WHERE sea.live LEADS: Deeper counterparty management (KYC, credit), more mature document management, '
    'broader clause library with template inheritance. These can be added to Trammo over time -- but sea.live '
    'cannot easily retrofit real-time solver integration into their architecture.',
    ORANGE
)


# Save
output = "/home/user/trading_desk/docs/contract_management_process_flows.pdf"
pdf.output(output)
print(f"PDF saved to {output}")
