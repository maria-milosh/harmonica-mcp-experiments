export type ExperimentStage =
  | 'registered'
  | 'initial_answered'
  | 'rephrased'
  | 'exposed'
  | 'outcome_recorded';

export function nextStage(current: ExperimentStage): ExperimentStage {
  switch (current) {
    case 'registered':
      return 'initial_answered';
    case 'initial_answered':
      return 'rephrased';
    case 'rephrased':
      return 'exposed';
    case 'exposed':
      return 'outcome_recorded';
    default:
      return 'outcome_recorded';
  }
}
