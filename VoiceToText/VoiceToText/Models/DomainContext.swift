import Foundation

// MARK: - Domain Context

struct DomainContext: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: String
    let promptVocabulary: [String]
    let promptModifier: String
    let resourceFile: String?

    /// Load the full vocabulary set from the bundled resource file (if any).
    func loadFullVocabulary() -> Set<String>? {
        guard let resource = resourceFile,
              let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let words = contents.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Set(words)
    }

    // MARK: - Built-in Contexts

    static let medical = DomainContext(
        id: "medical",
        name: "Medical",
        icon: "cross.case",
        promptVocabulary: [
            // Cardiovascular
            "hypertension", "tachycardia", "bradycardia", "arrhythmia", "atrial fibrillation",
            "myocardial infarction", "angina", "atherosclerosis", "cardiomyopathy", "endocarditis",
            "pericarditis", "aortic stenosis", "mitral regurgitation", "deep vein thrombosis",
            "pulmonary embolism", "congestive heart failure", "ejection fraction",
            // Respiratory
            "pneumonia", "bronchitis", "emphysema", "COPD", "asthma", "pneumothorax",
            "pleural effusion", "pulmonary fibrosis", "atelectasis", "bronchiectasis",
            // Gastrointestinal
            "gastroesophageal reflux", "GERD", "dysphagia", "cholecystitis", "cholelithiasis",
            "pancreatitis", "diverticulitis", "cirrhosis", "hepatitis", "Crohn's disease",
            "ulcerative colitis", "appendicitis", "peritonitis",
            // Neurological
            "cerebrovascular accident", "transient ischemic attack", "TIA", "neuropathy",
            "radiculopathy", "encephalopathy", "meningitis", "seizure", "epilepsy",
            "Parkinson's disease", "Alzheimer's disease", "multiple sclerosis",
            // Musculoskeletal
            "osteoarthritis", "rheumatoid arthritis", "osteoporosis", "scoliosis",
            "tendinitis", "bursitis", "fibromyalgia", "osteomyelitis",
            // Endocrine/Metabolic
            "diabetes mellitus", "hypothyroidism", "hyperthyroidism", "Cushing's syndrome",
            "Addison's disease", "hyperglycemia", "hypoglycemia", "metabolic syndrome",
            "hemoglobin A1c", "HbA1c", "thyroid-stimulating hormone", "TSH",
            // Renal/Urological
            "chronic kidney disease", "acute kidney injury", "nephrolithiasis",
            "glomerulonephritis", "pyelonephritis", "hematuria", "proteinuria",
            "benign prostatic hyperplasia", "BPH",
            // Hematology/Oncology
            "anemia", "thrombocytopenia", "leukocytosis", "lymphoma", "leukemia",
            "metastasis", "carcinoma", "sarcoma", "melanoma",
            // Infectious Disease
            "sepsis", "bacteremia", "cellulitis", "osteomyelitis", "endocarditis",
            "methicillin-resistant Staphylococcus aureus", "MRSA", "Clostridioides difficile",
            "C. diff",
            // Common Medications
            "metformin", "lisinopril", "amlodipine", "atorvastatin", "levothyroxine",
            "omeprazole", "metoprolol", "losartan", "gabapentin", "hydrochlorothiazide",
            "sertraline", "fluoxetine", "prednisone", "warfarin", "enoxaparin",
            "clopidogrel", "apixaban", "rivaroxaban", "insulin glargine", "dulaglutide",
            "empagliflozin", "acetaminophen", "ibuprofen", "amoxicillin", "azithromycin",
            "ciprofloxacin", "vancomycin", "piperacillin-tazobactam",
            // Anatomy
            "bilateral", "anterior", "posterior", "lateral", "medial", "proximal", "distal",
            "supine", "prone", "subcutaneous", "intramuscular", "intravenous",
            "peritoneal", "retroperitoneal", "intrathecal",
            // Clinical Terms
            "differential diagnosis", "prognosis", "etiology", "pathophysiology",
            "comorbidity", "contraindication", "prophylaxis", "palliative",
            "hemodynamically stable", "afebrile", "diaphoresis", "dyspnea", "orthopnea",
            "paresthesia", "edema", "erythema", "induration", "crepitus",
            // Vitals & Labs
            "blood pressure", "systolic", "diastolic", "oxygen saturation", "SpO2",
            "complete blood count", "CBC", "basic metabolic panel", "BMP",
            "comprehensive metabolic panel", "CMP", "troponin", "creatinine", "BUN",
            "prothrombin time", "INR", "lipase", "lactate", "D-dimer",
            // Procedures
            "intubation", "extubation", "thoracentesis", "paracentesis", "lumbar puncture",
            "colonoscopy", "endoscopy", "echocardiogram", "electrocardiogram", "ECG", "EKG",
            "CT scan", "MRI", "ultrasound", "catheterization",
        ],
        promptModifier: "Use standard medical terminology and abbreviations. Preserve drug names, dosages, and anatomical terms exactly as dictated. Format clinical observations clearly.",
        resourceFile: "medical-terms-en"
    )

    static let legal = DomainContext(
        id: "legal",
        name: "Legal",
        icon: "building.columns",
        promptVocabulary: [
            "plaintiff", "defendant", "appellant", "appellee", "petitioner", "respondent",
            "habeas corpus", "amicus curiae", "certiorari", "mandamus", "subpoena",
            "subpoena duces tecum", "voir dire", "pro bono", "pro se", "prima facie",
            "res judicata", "stare decisis", "mens rea", "actus reus",
            "tort", "negligence", "liability", "indemnification", "damages",
            "compensatory damages", "punitive damages", "injunction", "restraining order",
            "deposition", "interrogatory", "affidavit", "declaration", "stipulation",
            "motion to dismiss", "summary judgment", "directed verdict", "mistrial",
            "arraignment", "indictment", "plea bargain", "acquittal", "sentencing",
            "probation", "parole", "recidivism", "expungement",
            "jurisdiction", "venue", "standing", "statute of limitations",
            "due process", "equal protection", "sovereign immunity",
            "fiduciary duty", "breach of contract", "specific performance",
            "intellectual property", "patent infringement", "trademark",
            "copyright", "trade secret", "non-disclosure agreement", "NDA",
            "arbitration", "mediation", "class action", "derivative suit",
            "escrow", "lien", "encumbrance", "easement", "eminent domain",
            "quitclaim deed", "warranty deed", "title insurance",
            "power of attorney", "executor", "probate", "intestate", "testamentary",
            "trust", "beneficiary", "grantor", "trustee",
            "mens rea", "Miranda rights", "Fifth Amendment", "Fourteenth Amendment",
            "due diligence", "material adverse change", "force majeure",
            "consideration", "covenant", "warranty", "representation",
            "severability", "indemnity", "hold harmless",
        ],
        promptModifier: "Use formal legal language. Maintain precise legal terminology and proper citation format.",
        resourceFile: nil
    )

    static let technical = DomainContext(
        id: "technical",
        name: "Technical",
        icon: "terminal",
        promptVocabulary: [
            "Kubernetes", "Docker", "PostgreSQL", "MySQL", "MongoDB", "Redis", "Elasticsearch",
            "GraphQL", "REST API", "gRPC", "WebSocket", "OAuth", "JWT", "SAML",
            "microservices", "serverless", "containerization", "orchestration",
            "CI/CD", "GitHub Actions", "Jenkins", "Terraform", "Ansible", "CloudFormation",
            "AWS", "Azure", "GCP", "Lambda", "EC2", "S3", "CloudFront", "Route 53",
            "React", "Next.js", "Vue.js", "Angular", "Svelte", "TypeScript", "Node.js",
            "Python", "Django", "FastAPI", "Flask", "Go", "Rust", "Swift", "Kotlin",
            "TensorFlow", "PyTorch", "NumPy", "pandas", "scikit-learn",
            "NGINX", "Apache", "Caddy", "load balancer", "reverse proxy",
            "SSL/TLS", "HTTPS", "DNS", "CDN", "TCP/IP", "HTTP/2", "HTTP/3",
            "API gateway", "service mesh", "Istio", "Envoy",
            "Kafka", "RabbitMQ", "pub/sub", "event-driven", "message queue",
            "sharding", "replication", "CAP theorem", "eventual consistency",
            "idempotent", "middleware", "webhook", "cron job",
            "Git", "rebasing", "cherry-pick", "merge conflict",
            "unit test", "integration test", "end-to-end test", "TDD", "BDD",
            "observability", "Prometheus", "Grafana", "Datadog", "OpenTelemetry",
            "latency", "throughput", "p99", "SLA", "SLO", "SLI",
            "CRUD", "ORM", "SQL", "NoSQL", "indexing", "query optimization",
            "authentication", "authorization", "RBAC", "SSO", "MFA",
            "stdin", "stdout", "stderr", "regex", "cURL", "jq",
            "Xcode", "SwiftUI", "UIKit", "CoreData", "CloudKit",
            "npm", "yarn", "pip", "cargo", "brew", "apt",
        ],
        promptModifier: "Use precise technical terminology. Preserve library names, acronyms, and API references exactly.",
        resourceFile: nil
    )

    static let builtInContexts: [DomainContext] = [medical, legal, technical]

    static func context(forId id: String) -> DomainContext? {
        builtInContexts.first { $0.id == id }
    }
}
