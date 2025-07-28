# Architecture Diagrams

This directory contains the visual architecture diagrams for the cross-account EFS solution.

## Available Diagrams

### 1. High-Level Architecture
**File**: `banking-cross-account-same-region.png`

![Cross-Account EFS Architecture](banking-cross-account-same-region.png)

**Description**: Complete cross-account architecture showing the dual-write pattern between CoreBank and Satellite accounts. This diagram illustrates:
- Three AWS accounts (CoreBank + 2 Satellites)
- EKS clusters in each account
- Dual EFS mount pattern
- Cross-account data flow
- Core banking infrastructure (RDS, ElastiCache)

**Use Cases**:
- Executive presentations
- Architecture reviews
- Solution overview documentation
- Stakeholder communications

---

### 2. Network Architecture
**File**: `banking-network-cross-account.png`

![Network Architecture](banking-network-cross-account.png)

**Description**: Detailed network topology showing VPC peering connections, subnet design, and security group configurations. This diagram covers:
- VPC peering between accounts
- Multi-tier subnet architecture
- Security group relationships
- Network traffic flows
- EFS mount target placement

**Use Cases**:
- Network planning and design
- Security reviews
- Troubleshooting connectivity issues
- Infrastructure deployment planning

---

### 3. Security Architecture
**File**: `banking-security-cross-account.png`

![Security Architecture](banking-security-cross-account.png)

**Description**: Cross-account security model showing IAM roles, access controls, and security boundaries. This diagram details:
- Cross-account IAM role relationships
- EFS access points and policies
- Security control boundaries
- Trust relationships
- Access flow patterns

**Use Cases**:
- Security architecture reviews
- Compliance documentation
- IAM policy design
- Security audit preparation

## Diagram Usage Guidelines

### For Documentation
- Include relevant diagrams in architecture documents
- Reference diagrams in deployment guides
- Use diagrams in troubleshooting documentation
- Embed in README files for context

### For Presentations
- Use high-level architecture for executive briefings
- Use network diagrams for technical deep-dives
- Use security diagrams for compliance reviews
- Combine diagrams for comprehensive overviews

### For Development
- Reference during infrastructure coding
- Use for validation during deployment
- Include in code review processes
- Update diagrams when architecture changes

## Diagram Maintenance

### Update Process
1. **Architecture Changes**: Update diagrams when infrastructure changes
2. **Review Cycle**: Monthly review for accuracy
3. **Version Control**: Track changes in git history
4. **Documentation Sync**: Ensure diagrams match documentation

### Quality Standards
- **Clarity**: Diagrams should be easily understandable
- **Accuracy**: Must reflect actual implementation
- **Consistency**: Use consistent symbols and colors
- **Completeness**: Include all relevant components

### Tools Used
- **Diagrams as Code**: Python diagrams library
- **Format**: PNG for documentation embedding
- **Resolution**: High resolution for presentations
- **Accessibility**: Include alt text and descriptions

## Integration with Documentation

These diagrams are referenced throughout the documentation:

- **README.md**: High-level architecture overview
- **docs/architecture/overview.md**: All three diagrams with detailed explanations
- **docs/architecture/network-design.md**: Network architecture with technical details
- **docs/architecture/security-model.md**: Security architecture with implementation details
- **docs/deployment/step-by-step-guide.md**: All diagrams for deployment context
- **architecture/specifications/infrastructure-requirements.md**: Technical specifications with visual context

## Feedback and Updates

If you notice any inaccuracies or have suggestions for improvements:

1. **Create an Issue**: Use GitHub issues to report diagram problems
2. **Submit a PR**: Update diagrams and submit pull request
3. **Documentation**: Update related documentation when changing diagrams
4. **Testing**: Verify diagrams match actual deployed infrastructure

## License

These diagrams are part of the overall project and are licensed under the MIT License. See the main LICENSE file for details.
