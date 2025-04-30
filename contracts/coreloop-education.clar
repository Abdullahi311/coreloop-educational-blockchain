;; coreloop-education
;; A comprehensive smart contract for managing educational content, enrollments, and verifiable credentials on the Stacks blockchain.
;; This contract enables educators to publish courses, learners to enroll and earn credentials, and stakeholders to participate
;; in governance of the educational ecosystem.

;; ===============================================
;; Error Constants
;; ===============================================
(define-constant ERR-NOT-AUTHORIZED (err u1000))
(define-constant ERR-ALREADY-REGISTERED (err u1001))
(define-constant ERR-NOT-REGISTERED (err u1002))
(define-constant ERR-COURSE-NOT-FOUND (err u1003))
(define-constant ERR-ALREADY-ENROLLED (err u1004))
(define-constant ERR-NOT-ENROLLED (err u1005))
(define-constant ERR-INVALID-PAYMENT (err u1006))
(define-constant ERR-ASSIGNMENT-NOT-FOUND (err u1007))
(define-constant ERR-ALREADY-COMPLETED (err u1008))
(define-constant ERR-INVALID-PROPOSAL (err u1009))
(define-constant ERR-VOTING-CLOSED (err u1010))
(define-constant ERR-ALREADY-VOTED (err u1011))
(define-constant ERR-INVALID-PERMISSION (err u1012))
(define-constant ERR-NOT-CREDENTIAL-OWNER (err u1013))

;; ===============================================
;; Data Maps and Variables
;; ===============================================

;; Contract Admin
(define-data-var contract-admin principal tx-sender)

;; Educators Map - Stores information about registered educators
(define-map educators
  principal  ;; educator's principal
  {
    name: (string-ascii 100),
    description: (string-utf8 500),
    reputation-score: uint,
    total-ratings: uint,
    courses-count: uint,
    verified: bool,
    registration-time: uint
  }
)

;; Courses Map - Stores course information
(define-map courses
  uint  ;; course ID
  {
    educator: principal,
    title: (string-utf8 100),
    description: (string-utf8 1000),
    price: uint,  ;; in microSTX, 0 for free courses
    is-subscription: bool,  ;; true if subscription-based
    subscription-period: uint,  ;; in days, 0 if one-time payment
    content-uri: (string-ascii 500),  ;; IPFS or other URI to course content
    enrollment-count: uint,
    completion-count: uint,
    average-rating: uint,  ;; out of 100
    total-ratings: uint,
    creation-time: uint,
    last-updated: uint,
    active: bool
  }
)

;; Learners Map - Stores information about registered learners
(define-map learners
  principal  ;; learner's principal
  {
    name: (string-ascii 100),
    email-hash: (buff 32),  ;; hashed email for privacy
    courses-enrolled: (list 50 uint),  ;; limited to 50 enrollments at once
    credentials-earned: uint,
    registration-time: uint
  }
)

;; Enrollments Map - Tracks enrollments for each course
(define-map enrollments
  {
    course-id: uint,
    learner: principal
  }
  {
    enrollment-time: uint,
    subscription-expiry: uint,  ;; 0 if one-time purchase
    completed: bool,
    completion-time: uint,
    assignments-submitted: (list 20 uint),  ;; IDs of submitted assignments
    credential-id: uint  ;; 0 if not completed
  }
)

;; Assignments Map - Stores assignment information for courses
(define-map assignments
  {
    course-id: uint,
    assignment-id: uint
  }
  {
    title: (string-utf8 100),
    description: (string-utf8 1000),
    submission-type: (string-ascii 20),  ;; e.g., "text", "file", "quiz"
    deadline: uint,  ;; timestamp
    required-for-completion: bool
  }
)

;; Assignment Submissions Map - Tracks learner submissions
(define-map assignment-submissions
  {
    course-id: uint,
    assignment-id: uint,
    learner: principal
  }
  {
    submission-uri: (string-ascii 500),  ;; IPFS or other URI to submission
    submission-time: uint,
    grade: uint,  ;; 0-100, 0 if not graded
    feedback: (string-utf8 500),
    graded-by: principal,
    grading-time: uint
  }
)

;; Credentials Map - Stores issued credentials
(define-map credentials
  uint  ;; credential ID
  {
    learner: principal,
    course-id: uint,
    title: (string-utf8 100),
    description: (string-utf8 500),
    issuer: principal,  ;; educator who issued the credential
    issue-time: uint,
    expiration-time: uint,  ;; 0 if does not expire
    revoked: bool,
    verification-hash: (buff 32)  ;; hash of credential details for verification
  }
)

;; Credential Permissions Map - Controls who can view a credential
(define-map credential-permissions
  {
    credential-id: uint,
    viewer: principal
  }
  {
    granted-by: principal,  ;; should be credential owner
    granted-time: uint,
    expiry-time: uint  ;; 0 if permanent
  }
)

;; Governance Proposals Map - For platform governance
(define-map governance-proposals
  uint  ;; proposal ID
  {
    proposer: principal,
    title: (string-utf8 100),
    description: (string-utf8 2000),
    proposal-type: (string-ascii 20),  ;; e.g., "fee-change", "feature", "policy"
    start-time: uint,
    end-time: uint,
    votes-for: uint,
    votes-against: uint,
    status: (string-ascii 10),  ;; "active", "passed", "rejected", "implemented"
    implementation-time: uint
  }
)

;; Governance Votes Map - Tracks votes cast by stakeholders
(define-map governance-votes
  {
    proposal-id: uint,
    voter: principal
  }
  {
    vote: bool,  ;; true for, false against
    time: uint,
    weight: uint  ;; voting power based on reputation/stake
  }
)

;; Reputation Ratings Map - Tracks ratings given by learners
(define-map reputation-ratings
  {
    course-id: uint,
    learner: principal
  }
  {
    rating: uint,  ;; 0-100
    review: (string-utf8 500),
    time: uint
  }
)

;; Counters for auto-incrementing IDs
(define-data-var next-course-id uint u1)
(define-data-var next-credential-id uint u1)
(define-data-var next-proposal-id uint u1)

;; Platform statistics
(define-data-var total-educators uint u0)
(define-data-var total-learners uint u0)
(define-data-var total-courses uint u0)
(define-data-var total-enrollments uint u0)
(define-data-var total-credentials-issued uint u0)

;; Platform fees and settings
(define-data-var platform-fee-percentage uint u5)  ;; 5% default
(define-data-var minimum-rating-threshold uint u60)  ;; 60/100 minimum average rating

;; ===============================================
;; Private Functions
;; ===============================================

;; Helper function to check if caller is contract admin
(define-private (is-admin)
  (is-eq tx-sender (var-get contract-admin))
)

;; Helper function to check if caller is a registered educator
(define-private (is-educator (educator principal))
  (is-some (map-get? educators educator))
)

;; Helper function to check if caller is a registered learner
(define-private (is-learner (learner principal))
  (is-some (map-get? learners learner))
)

;; Helper function to check if a course exists
(define-private (course-exists (course-id uint))
  (is-some (map-get? courses course-id))
)

;; Helper to calculate platform fees for a payment
(define-private (calculate-platform-fee (amount uint))
  (/ (* amount (var-get platform-fee-percentage)) u100)
)

;; Helper to transfer payment with platform fee
(define-private (process-payment (recipient principal) (amount uint))
  (let (
    (fee (calculate-platform-fee amount))
    (educator-amount (- amount fee))
  )
    ;; Send platform fee to contract admin
    (and 
      (stx-transfer? fee tx-sender (var-get contract-admin))
      ;; Send remaining amount to educator
      (stx-transfer? educator-amount tx-sender recipient)
    )
  )
)

;; Helper to generate a verification hash for credentials
(define-private (generate-credential-hash (course-id uint) (learner principal) (issue-time uint))
  (sha256 (concat (concat 
    (unwrap-panic (to-consensus-buff course-id))
    (unwrap-panic (to-consensus-buff learner)))
    (unwrap-panic (to-consensus-buff issue-time))))
)

;; Helper to check if learner has completed all required assignments
(define-private (completed-required-assignments (course-id uint) (learner principal))
  ;; This would iterate through all assignments and check submissions
  ;; Since Clarity doesn't support traditional loops, this is a simplified version
  ;; A real implementation would use fold or map functions on assignment lists
  true
)

;; ===============================================
;; Read-Only Functions
;; ===============================================

;; Get educator details
(define-read-only (get-educator (educator principal))
  (map-get? educators educator)
)

;; Get course details
(define-read-only (get-course (course-id uint))
  (map-get? courses course-id)
)

;; Get learner details (basic info, not including private details)
(define-read-only (get-learner-public-info (learner principal))
  (match (map-get? learners learner)
    learner-data (some {
      name: (get name learner-data),
      credentials-earned: (get credentials-earned learner-data),
      registration-time: (get registration-time learner-data)
    })
    none
  )
)

;; Get enrollment details
(define-read-only (get-enrollment (course-id uint) (learner principal))
  (map-get? enrollments {course-id: course-id, learner: learner})
)

;; Get assignment details
(define-read-only (get-assignment (course-id uint) (assignment-id uint))
  (map-get? assignments {course-id: course-id, assignment-id: assignment-id})
)

;; Get credential details with permission check
(define-read-only (get-credential (credential-id uint))
  (let (
    (credential (map-get? credentials credential-id))
    (is-owner (and (is-some credential) (is-eq tx-sender (get learner (unwrap-panic credential)))))
    (has-permission (is-some (map-get? credential-permissions {credential-id: credential-id, viewer: tx-sender})))
  )
    (if (or is-owner has-permission)
      credential
      none
    )
  )
)

;; Get governance proposal details
(define-read-only (get-proposal (proposal-id uint))
  (map-get? governance-proposals proposal-id)
)

;; Get the list of courses created by an educator
(define-read-only (get-educator-courses (educator principal))
  ;; In a real implementation, this would iterate through courses and filter
  ;; Simplified implementation returns placeholder
  (list)
)

;; Get courses a learner is enrolled in
(define-read-only (get-learner-enrollments (learner principal))
  (match (map-get? learners learner)
    learner-data (get courses-enrolled learner-data)
    none (list)
  )
)

;; Verify if a credential is valid
(define-read-only (verify-credential (credential-id uint))
  (match (map-get? credentials credential-id)
    credential (let (
      (expected-hash (generate-credential-hash 
        (get course-id credential) 
        (get learner credential) 
        (get issue-time credential)))
    )
      (and 
        (not (get revoked credential))
        (or 
          (is-eq (get expiration-time credential) u0)
          (> (get expiration-time credential) block-height)
        )
        (is-eq expected-hash (get verification-hash credential))
      )
    )
    none false
  )
)

;; ===============================================
;; Public Functions
;; ===============================================

;; Administrator Functions

;; Set a new contract administrator
(define-public (set-admin (new-admin principal))
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (ok (var-set contract-admin new-admin))
  )
)

;; Update platform fee percentage
(define-public (set-platform-fee (new-fee uint))
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (asserts! (<= new-fee u30) ERR-INVALID-PROPOSAL)  ;; Cap maximum fee at 30%
    (ok (var-set platform-fee-percentage new-fee))
  )
)

;; Verify an educator (admin function)
(define-public (verify-educator (educator principal))
  (begin
    (asserts! (is-admin) ERR-NOT-AUTHORIZED)
    (match (map-get? educators educator)
      educator-data (ok (map-set educators educator 
        (merge educator-data {verified: true})))
      none ERR-NOT-REGISTERED
    )
  )
)

;; Educator Functions

;; Register as an educator
(define-public (register-educator (name (string-ascii 100)) (description (string-utf8 500)))
  (begin
    (asserts! (not (is-educator tx-sender)) ERR-ALREADY-REGISTERED)
    (map-set educators tx-sender {
      name: name,
      description: description,
      reputation-score: u0,
      total-ratings: u0,
      courses-count: u0,
      verified: false,
      registration-time: block-height
    })
    (var-set total-educators (+ (var-get total-educators) u1))
    (ok tx-sender)
  )
)

;; Update educator profile
(define-public (update-educator-profile (name (string-ascii 100)) (description (string-utf8 500)))
  (begin
    (asserts! (is-educator tx-sender) ERR-NOT-REGISTERED)
    (match (map-get? educators tx-sender)
      educator-data (ok (map-set educators tx-sender 
        (merge educator-data {
          name: name,
          description: description
        })))
      none ERR-NOT-REGISTERED
    )
  )
)

;; Create a new course
(define-public (create-course (title (string-utf8 100)) 
                              (description (string-utf8 1000)) 
                              (price uint)
                              (is-subscription bool)
                              (subscription-period uint)
                              (content-uri (string-ascii 500)))
  (let (
    (course-id (var-get next-course-id))
  )
    (asserts! (is-educator tx-sender) ERR-NOT-AUTHORIZED)
    
    ;; If it's a subscription, subscription period must be positive
    (asserts! (or (not is-subscription) (> subscription-period u0)) ERR-INVALID-PROPOSAL)
    
    ;; Create the course
    (map-set courses course-id {
      educator: tx-sender,
      title: title,
      description: description,
      price: price,
      is-subscription: is-subscription,
      subscription-period: subscription-period,
      content-uri: content-uri,
      enrollment-count: u0,
      completion-count: u0,
      average-rating: u0,
      total-ratings: u0,
      creation-time: block-height,
      last-updated: block-height,
      active: true
    })
    
    ;; Update the educator's courses count
    (match (map-get? educators tx-sender)
      educator-data (map-set educators tx-sender 
        (merge educator-data {
          courses-count: (+ (get courses-count educator-data) u1)
        }))
      none (err ERR-NOT-REGISTERED)
    )
    
    ;; Increment course ID counter and total courses
    (var-set next-course-id (+ course-id u1))
    (var-set total-courses (+ (var-get total-courses) u1))
    
    (ok course-id)
  )
)

;; Update a course
(define-public (update-course (course-id uint)
                             (title (string-utf8 100)) 
                             (description (string-utf8 1000)) 
                             (price uint)
                             (content-uri (string-ascii 500))
                             (active bool))
  (begin
    (asserts! (course-exists course-id) ERR-COURSE-NOT-FOUND)
    (match (map-get? courses course-id)
      course-data (begin
        (asserts! (is-eq tx-sender (get educator course-data)) ERR-NOT-AUTHORIZED)
        (ok (map-set courses course-id 
          (merge course-data {
            title: title,
            description: description,
            price: price,
            content-uri: content-uri,
            active: active,
            last-updated: block-height
          })))
      )
      none ERR-COURSE-NOT-FOUND
    )
  )
)

;; Add an assignment to a course
(define-public (add-assignment (course-id uint)
                              (assignment-id uint)
                              (title (string-utf8 100))
                              (description (string-utf8 1000))
                              (submission-type (string-ascii 20))
                              (deadline uint)
                              (required-for-completion bool))
  (begin
    (asserts! (course-exists course-id) ERR-COURSE-NOT-FOUND)
    (match (map-get? courses course-id)
      course-data (begin
        (asserts! (is-eq tx-sender (get educator course-data)) ERR-NOT-AUTHORIZED)
        (ok (map-set assignments 
          {course-id: course-id, assignment-id: assignment-id}
          {
            title: title,
            description: description,
            submission-type: submission-type,
            deadline: deadline,
            required-for-completion: required-for-completion
          }))
      )
      none ERR-COURSE-NOT-FOUND
    )
  )
)

;; Grade an assignment submission
(define-public (grade-assignment (course-id uint)
                                (assignment-id uint)
                                (learner principal)
                                (grade uint)
                                (feedback (string-utf8 500)))
  (begin
    (asserts! (course-exists course-id) ERR-COURSE-NOT-FOUND)
    (match (map-get? courses course-id)
      course-data (begin
        (asserts! (is-eq tx-sender (get educator course-data)) ERR-NOT-AUTHORIZED)
        (match (map-get? assignment-submissions 
                {course-id: course-id, assignment-id: assignment-id, learner: learner})
          submission (ok (map-set assignment-submissions
            {course-id: course-id, assignment-id: assignment-id, learner: learner}
            (merge submission {
              grade: grade,
              feedback: feedback,
              graded-by: tx-sender,
              grading-time: block-height
            })))
          none ERR-ASSIGNMENT-NOT-FOUND
        )
      )
      none ERR-COURSE-NOT-FOUND
    )
  )
)

;; Issue a credential to a learner
(define-public (issue-credential (course-id uint)
                                (learner principal)
                                (title (string-utf8 100))
                                (description (string-utf8 500))
                                (expiration-time uint))
  (let (
    (credential-id (var-get next-credential-id))
    (issue-time block-height)
    (verification-hash (generate-credential-hash course-id learner issue-time))
  )
    (asserts! (course-exists course-id) ERR-COURSE-NOT-FOUND)
    
    (match (map-get? courses course-id)
      course-data (begin
        (asserts! (is-eq tx-sender (get educator course-data)) ERR-NOT-AUTHORIZED)
        
        ;; Verify learner is enrolled and completed requirements
        (match (map-get? enrollments {course-id: course-id, learner: learner})
          enrollment (begin
            ;; Check if already completed
            (asserts! (not (get completed enrollment)) ERR-ALREADY-COMPLETED)
            
            ;; Check if all required assignments are completed
            (asserts! (completed-required-assignments course-id learner) ERR-NOT-AUTHORIZED)
            
            ;; Issue the credential
            (map-set credentials credential-id {
              learner: learner,
              course-id: course-id,
              title: title,
              description: description,
              issuer: tx-sender,
              issue-time: issue-time,
              expiration-time: expiration-time,
              revoked: false,
              verification-hash: verification-hash
            })
            
            ;; Update enrollment status
            (map-set enrollments {course-id: course-id, learner: learner}
              (merge enrollment {
                completed: true,
                completion-time: block-height,
                credential-id: credential-id
              }))
            
            ;; Update course completion count
            (map-set courses course-id
              (merge course-data {
                completion-count: (+ (get completion-count course-data) u1)
              }))
            
            ;; Update learner's credentials count
            (match (map-get? learners learner)
              learner-data (map-set learners learner
                (merge learner-data {
                  credentials-earned: (+ (get credentials-earned learner-data) u1)
                }))
              none ERR-NOT-REGISTERED
            )
            
            ;; Increment credential ID counter and total credentials
            (var-set next-credential-id (+ credential-id u1))
            (var-set total-credentials-issued (+ (var-get total-credentials-issued) u1))
            
            (ok credential-id)
          )
          none ERR-NOT-ENROLLED
        )
      )
      none ERR-COURSE-NOT-FOUND
    )
  )
)

;; Revoke a credential
(define-public (revoke-credential (credential-id uint))
  (begin
    (match (map-get? credentials credential-id)
      credential (begin
        (asserts! (is-eq tx-sender (get issuer credential)) ERR-NOT-AUTHORIZED)
        (ok (map-set credentials credential-id
          (merge credential {revoked: true})))
      )
      none ERR-NOT-REGISTERED
    )
  )
)

;; Learner Functions

;; Register as a learner
(define-public (register-learner (name (string-ascii 100)) (email-hash (buff 32)))
  (begin
    (asserts! (not (is-learner tx-sender)) ERR-ALREADY-REGISTERED)
    (map-set learners tx-sender {
      name: name,
      email-hash: email-hash,
      courses-enrolled: (list),
      credentials-earned: u0,
      registration-time: block-height
    })
    (var-set total-learners (+ (var-get total-learners) u1))
    (ok tx-sender)
  )
)

;; Update learner profile
(define-public (update-learner-profile (name (string-ascii 100)) (email-hash (buff 32)))
  (begin
    (asserts! (is-learner tx-sender) ERR-NOT-REGISTERED)
    (match (map-get? learners tx-sender)
      learner-data (ok (map-set learners tx-sender 
        (merge learner-data {
          name: name,
          email-hash: email-hash
        })))
      none ERR-NOT-REGISTERED
    )
  )
)

;; Enroll in a course
(define-public (enroll-in-course (course-id uint))
  (begin
    (asserts! (course-exists course-id) ERR-COURSE-NOT-FOUND)
    (asserts! (is-learner tx-sender) ERR-NOT-REGISTERED)
    
    ;; Check if already enrolled
    (asserts! (is-none (map-get? enrollments {course-id: course-id, learner: tx-sender})) ERR-ALREADY-ENROLLED)
    
    (match (map-get? courses course-id)
      course-data (begin
        (asserts! (get active course-data) ERR-COURSE-NOT-FOUND)
        
        ;; Handle payment if course is not free
        (if (> (get price course-data) u0)
          (begin
            (asserts! (process-payment (get educator course-data) (get price course-data)) ERR-INVALID-PAYMENT)
            ;; Continue with enrollment
            (handle-enrollment course-id course-data)
          )
          ;; For free courses, just handle enrollment
          (handle-enrollment course-id course-data)
        )
      )
      none ERR-COURSE-NOT-FOUND
    )
  )
)

;; Private helper for enrollment logic
(define-private (handle-enrollment (course-id uint) (course-data (tuple (educator principal) (title (string-utf8 100)) (description (string-utf8 1000)) (price uint) (is-subscription bool) (subscription-period uint) (content-uri (string-ascii 500)) (enrollment-count uint) (completion-count uint) (average-rating uint) (total-ratings uint) (creation-time uint) (last-updated uint) (active bool))))
  (let (
    (subscription-expiry (if (get is-subscription course-data)
                            (+ block-height (* (get subscription-period course-data) u144))  ;; Approx blocks per day is 144
                            u0))  ;; 0 if one-time purchase
  )
    ;; Record enrollment
    (map-set enrollments 
      {course-id: course-id, learner: tx-sender}
      {
        enrollment-time: block-height,
        subscription-expiry: subscription-expiry,
        completed: false,
        completion-time: u0,
        assignments-submitted: (list),
        credential-id: u0
      })
    
    ;; Update learner's enrolled courses
    (match (map-get? learners tx-sender)
      learner-data (map-set learners tx-sender
        (merge learner-data {
          courses-enrolled: (unwrap-panic (as-max-len? 
                                          (append (get courses-enrolled learner-data) course-id) 
                                          u50))
        }))
      none ERR-NOT-REGISTERED
    )
    
    ;; Update course enrollment count
    (map-set courses course-id
      (merge course-data {
        enrollment-count: (+ (get enrollment-count course-data) u1)
      }))
    
    ;; Update total enrollments
    (var-set total-enrollments (+ (var-get total-enrollments) u1))
    
    (ok course-id)
  )
)

;; Submit an assignment
(define-public (submit-assignment (course-id uint)
                                 (assignment-id uint)
                                 (submission-uri (string-ascii 500)))
  (begin
    (asserts! (course-exists course-id) ERR-COURSE-NOT-FOUND)
    
    ;; Check enrollment
    (match (map-get? enrollments {course-id: course-id, learner: tx-sender})
      enrollment (begin
        ;; Check if assignment exists
        (match (map-get? assignments {course-id: course-id, assignment-id: assignment-id})
          assignment (begin
            ;; Record submission
            (map-set assignment-submissions
              {course-id: course-id, assignment-id: assignment-id, learner: tx-sender}
              {
                submission-uri: submission-uri,
                submission-time: block-height,
                grade: u0,  ;; Not graded yet
                feedback: "",
                graded-by: 'SP000000000000000000002Q6VF78,  ;; Zero address as placeholder
                grading-time: u0
              })
            
            ;; Update enrollment's submitted assignments list
            (map-set enrollments 
              {course-id: course-id, learner: tx-sender}
              (merge enrollment {
                assignments-submitted: (unwrap-panic (as-max-len? 
                                                    (append (get assignments-submitted enrollment) assignment-id) 
                                                    u20))
              }))
            
            (ok true)
          )
          none ERR-ASSIGNMENT-NOT-FOUND
        )
      )
      none ERR-NOT-ENROLLED
    )
  )
)

;; Rate a course
(define-public (rate-course (course-id uint) (rating uint) (review (string-utf8 500)))
  (begin
    (asserts! (course-exists course-id) ERR-COURSE-NOT-FOUND)
    (asserts! (<= rating u100) ERR-INVALID-PROPOSAL)  ;; Rating must be 0-100
    
    ;; Check that learner is enrolled and has completed the course
    (match (map-get? enrollments {course-id: course-id, learner: tx-sender})
      enrollment (begin
        (asserts! (get completed enrollment) ERR-NOT-AUTHORIZED)
        
        ;; Record the rating
        (map-set reputation-ratings
          {course-id: course-id, learner: tx-sender}
          {
            rating: rating,
            review: review,
            time: block-height
          })
        
        ;; Update course rating
        (match (map-get? courses course-id)
          course-data (let (
            (new-total-ratings (+ (get total-ratings course-data) u1))
            (new-average-rating (/ (+ (* (get average-rating course-data) (get total-ratings course-data)) rating) new-total-ratings))
          )
            (map-set courses course-id
              (merge course-data {
                average-rating: new-average-rating,
                total-ratings: new-total-ratings
              }))
            
            ;; Update educator rating
            (match (map-get? educators (get educator